package sh.runr.runtime;

import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.stream.Stream;

/**
 * RunR Java runtime: serves the RunR HTTP contract on $PORT and calls the function's handler for
 * every request, or (RUNR_MODE=schedule) calls it once, prints the result and exits.
 *
 * The handler is the public method RUNR_HANDLER (default "handler") of the class named like
 * RUNR_FILENAME (Main.java: class Main, in any package), static or on an instance made with the
 * class's no-argument constructor:
 *
 *   public static Object handler(Map<String, Object> event, Map<String, Object> context)
 *
 * event is the request body parsed as a JSON object, else {"body": "<the body>"}; context holds
 * method, path and headers (lower-case names). A Map result with statusCode / headers / body is a
 * response envelope; anything else is the body (JSON unless it is a string with another
 * Content-Type). A CompletionStage or Future result is waited for.
 */
public final class Server {
    private static final Map<String, String> CORS = Map.of(
            "Access-Control-Allow-Origin", "*",
            "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS",
            "Access-Control-Allow-Headers", "Content-Type, Authorization",
            "Access-Control-Max-Age", "86400");

    private Server() {
    }

    public static void main(String[] args) throws Exception {
        Invoker invoker;
        try {
            invoker = Invoker.load();
        } catch (Exception e) {
            System.err.println("Error: " + e.getMessage());
            System.exit(1);
            return;
        }

        if ("schedule".equals(env("RUNR_MODE", "http"))) {
            schedule(invoker);
            return;
        }

        int port = Integer.parseInt(env("PORT", "8080"));
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 256);
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.createContext("/", exchange -> handle(exchange, invoker));
        server.start();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> server.stop(1)));
        System.out.println("RunR Java runtime listening on :" + port);
    }

    private static String env(String name, String fallback) {
        String v = System.getenv(name);
        return v == null || v.isEmpty() ? fallback : v;
    }

    private static void schedule(Invoker invoker) {
        Map<String, Object> event = new LinkedHashMap<>();
        event.put("trigger", "schedule");
        Map<String, Object> context = new LinkedHashMap<>();
        context.put("mode", "schedule");
        try {
            Object result = invoker.invoke(event, context);
            boolean structured = result instanceof Map || result instanceof Iterable || result instanceof Record
                    || (result != null && result.getClass().isArray());
            System.out.println(structured ? Json.write(result) : String.valueOf(result));
            System.out.flush();
        } catch (Throwable t) {
            System.err.println("Error: " + t);
            t.printStackTrace();
            System.exit(1);
        }
    }

    private static void handle(HttpExchange ex, Invoker invoker) {
        String method = ex.getRequestMethod();
        String path = ex.getRequestURI().toString();
        int status = 500;
        try (ex) {
            Headers in = ex.getRequestHeaders();

            // Knative probe: not passed to the handler
            if (in.containsKey("K-Network-Probe") || in.containsKey("K-Kubelet-Probe")) {
                status = 200;
                send(ex, 200, Map.of(), "ok".getBytes(StandardCharsets.UTF_8));
                return;
            }

            // CORS preflight
            if ("OPTIONS".equals(method)) {
                status = 204;
                send(ex, 204, CORS, new byte[0]);
                return;
            }

            byte[] raw;
            try (InputStream body = ex.getRequestBody()) {
                raw = body.readAllBytes();
            }
            String body = new String(raw, StandardCharsets.UTF_8);

            Map<String, Object> event = event(body);
            Map<String, String> headers = new LinkedHashMap<>();
            for (Map.Entry<String, List<String>> h : in.entrySet()) {
                headers.put(h.getKey().toLowerCase(Locale.ROOT), String.join(", ", h.getValue()));
            }
            Map<String, Object> context = new LinkedHashMap<>();
            context.put("method", method);
            context.put("path", path);
            context.put("headers", headers);

            Object result;
            try {
                result = invoker.invoke(event, context);
            } catch (Throwable t) {
                t.printStackTrace();
                status = 500;
                Map<String, String> h = new LinkedHashMap<>();
                h.put("Access-Control-Allow-Origin", "*");
                h.put("Content-Type", "application/json");
                send(ex, 500, h, Json.write(Map.of("error", String.valueOf(t))).getBytes(StandardCharsets.UTF_8));
                return;
            }
            status = respond(ex, result);
        } catch (IOException e) {
            System.err.println("[runr] " + method + " " + path + ": " + e.getMessage());
        } finally {
            System.out.println("[runr] " + method + " " + path + " " + status);
        }
    }

    /** The request body as the handler's event: a JSON object, else {"body": body}. */
    private static Map<String, Object> event(String body) {
        Map<String, Object> event = new LinkedHashMap<>();
        if (body.isEmpty()) {
            return event;
        }
        try {
            if (Json.parse(body) instanceof Map<?, ?> m) {
                for (Map.Entry<?, ?> e : m.entrySet()) {
                    event.put(String.valueOf(e.getKey()), e.getValue());
                }
                return event;
            }
        } catch (IllegalArgumentException notJson) {
            // the raw body below
        }
        event.put("body", body);
        return event;
    }

    /** Writes the handler's result; returns the status. */
    private static int respond(HttpExchange ex, Object result) throws IOException {
        int status = 200;
        Object body = result;
        Map<String, Object> custom = Map.of();
        if (result instanceof Map<?, ?> m) {
            if (m.get("statusCode") instanceof Number n) {
                status = n.intValue();
            }
            if (m.get("headers") instanceof Map<?, ?> h) {
                Map<String, Object> copy = new LinkedHashMap<>();
                h.forEach((k, v) -> copy.put(String.valueOf(k), v));
                custom = copy;
            }
            if (m.containsKey("body")) {
                body = m.get("body");
            }
        }

        // user headers override the defaults, whatever their case
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Access-Control-Allow-Origin", "*");
        headers.put("Content-Type", "application/json");
        for (Map.Entry<String, Object> e : custom.entrySet()) {
            headers.keySet().removeIf(k -> k.equalsIgnoreCase(e.getKey()));
            headers.put(e.getKey(), String.valueOf(e.getValue()));
        }
        String contentType = headers.entrySet().stream()
                .filter(e -> e.getKey().equalsIgnoreCase("Content-Type"))
                .map(Map.Entry::getValue).findFirst().orElse("");

        String text = body instanceof CharSequence s && !contentType.contains("application/json")
                ? s.toString() : Json.write(body);
        if (status < 100 || status > 999) {
            status = 500;
        }
        send(ex, status, headers, text.getBytes(StandardCharsets.UTF_8));
        return status;
    }

    private static void send(HttpExchange ex, int status, Map<String, String> headers, byte[] body) throws IOException {
        Headers out = ex.getResponseHeaders();
        headers.forEach(out::set);
        boolean empty = body.length == 0 || status == 204 || status == 304 || status < 200;
        ex.sendResponseHeaders(status, empty ? -1 : body.length);
        if (!empty) {
            try (OutputStream os = ex.getResponseBody()) {
                os.write(body);
            }
        }
    }

    /** The handler method of the function and how to call it. */
    static final class Invoker {
        private final Method method;
        private final Object target;

        private Invoker(Method method, Object target) {
            this.method = method;
            this.target = target;
        }

        static Invoker load() throws Exception {
            String filename = env("RUNR_FILENAME", "Main.java");
            String handler = env("RUNR_HANDLER", "handler");
            String name = Paths.get(filename).getFileName().toString();
            int dot = name.lastIndexOf('.');
            if (dot > 0) {
                name = name.substring(0, dot);
            }

            Class<?> cls = findClass(name);
            if (cls == null) {
                throw new IllegalStateException("class '" + name + "' not found (" + filename + " compiled into the function's classes?)");
            }

            // the method named exactly like the handler, else one whose name differs only in case;
            // the one taking (event, context) before (event) before ()
            Method found = null;
            for (boolean exact : new boolean[] {true, false}) {
                for (Method m : cls.getMethods()) {
                    if (exact ? !m.getName().equals(handler) : !m.getName().equalsIgnoreCase(handler)) {
                        continue;
                    }
                    boolean fits = m.getParameterCount() <= 2;
                    for (Class<?> t : m.getParameterTypes()) {
                        fits &= t.isAssignableFrom(LinkedHashMap.class);
                    }
                    if (fits && (found == null || m.getParameterCount() > found.getParameterCount())) {
                        found = m;
                    }
                }
                if (found != null) {
                    break;
                }
            }
            if (found == null) {
                throw new IllegalStateException("handler '" + handler + "' not found in " + cls.getName()
                        + ": a public method " + handler + "(Map<String, Object> event, Map<String, Object> context)");
            }
            Object target = null;
            if (!Modifier.isStatic(found.getModifiers())) {
                target = cls.getDeclaredConstructor().newInstance();
            }
            return new Invoker(found, target);
        }

        /** The class NAME: in the default package, else the first NAME.class in a package of a classpath directory. */
        private static Class<?> findClass(String name) throws IOException {
            ClassLoader loader = Thread.currentThread().getContextClassLoader();
            try {
                return Class.forName(name, true, loader);
            } catch (ClassNotFoundException notInDefaultPackage) {
                // look in the packages below
            }
            for (String entry : System.getProperty("java.class.path", "").split(java.io.File.pathSeparator)) {
                Path root = Paths.get(entry);
                if (!Files.isDirectory(root)) {
                    continue;
                }
                List<Path> hits = new ArrayList<>();
                try (Stream<Path> files = Files.walk(root)) {
                    files.filter(f -> f.getFileName().toString().equals(name + ".class")).forEach(hits::add);
                }
                hits.sort(Comparator.comparingInt(Path::getNameCount).thenComparing(Path::toString));
                for (Path hit : hits) {
                    String rel = root.relativize(hit).toString();
                    String fqcn = rel.substring(0, rel.length() - ".class".length()).replace(java.io.File.separatorChar, '.');
                    try {
                        return Class.forName(fqcn, true, loader);
                    } catch (ClassNotFoundException | LinkageError ignored) {
                        // the next one
                    }
                }
            }
            return null;
        }

        Object invoke(Map<String, Object> event, Map<String, Object> context) throws Throwable {
            Object[] args = switch (method.getParameterCount()) {
                case 0 -> new Object[0];
                case 1 -> new Object[] {event};
                default -> new Object[] {event, context};
            };
            Object result;
            try {
                result = method.invoke(target, args);
            } catch (InvocationTargetException e) {
                throw e.getCause();
            }
            try {
                if (result instanceof CompletionStage<?> stage) {
                    result = stage.toCompletableFuture().get();
                } else if (result instanceof Future<?> future) {
                    result = future.get();
                }
            } catch (ExecutionException e) {
                throw e.getCause();
            }
            return result;
        }
    }
}
