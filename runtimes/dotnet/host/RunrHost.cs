// RunR .NET runtime: the handler server, compiled into every function together with its code
// (runr-build). It serves the RunR HTTP contract on $PORT with Kestrel and calls the function's
// handler for every request, or (RUNR_MODE=schedule) calls it once, prints the result and exits.
//
/// The handler is the public method named like RUNR_HANDLER (default "Handler"; in another case when
// no method has that exact name)
// of a class of the function, static or on an instance made with the class's parameterless
// constructor; a class named like RUNR_FILENAME (Function.cs: Function) is looked at first:
//
//   public static object Handler(JsonNode? input, IDictionary<string, object?> context)
//
// The first parameter is the request body: a JsonNode / JsonObject / JsonElement of the body
// parsed as a JSON object (else {"body": "<the body>"}), the raw body for a string, or that JSON
// deserialized into any other type (property names in any case). The second gets method, path and
// headers (lower-case names). Both are optional. The result may be a Task or ValueTask; it is
// serialized with System.Text.Json (camelCase properties): an object with statusCode / headers /
// body is a response envelope, anything else is the body (JSON unless it is a string with another
// Content-Type).
#nullable enable

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Extensions;
using Microsoft.Extensions.Hosting;

namespace Runr.Runtime
{
    internal static class Host
    {
        private static readonly JsonSerializerOptions Options = new()
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        };

        private static readonly UTF8Encoding Utf8 = new(false);

        public static async Task<int> Main(string[] args)
        {
            Invoker invoker;
            try
            {
                invoker = Invoker.Load(Assembly.GetExecutingAssembly());
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"Error: {e.Message}");
                return 1;
            }

            if (Env("RUNR_MODE", "http") == "schedule")
            {
                return await Schedule(invoker);
            }

            // Kestrel alone: no configuration files, no logging providers, no routing
            var port = int.Parse(Env("PORT", "8080"), CultureInfo.InvariantCulture);
            var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions { Args = args });
            builder.WebHost.UseKestrelCore().ConfigureKestrel(options =>
            {
                options.AddServerHeader = false;
                options.ListenAnyIP(port);
            });
            var app = builder.Build();
            app.Run(ctx => Handle(ctx, invoker));
            await app.StartAsync();
            Console.WriteLine($"RunR .NET runtime listening on :{port}");
            await app.WaitForShutdownAsync();
            return 0;
        }

        private static string Env(string name, string fallback)
        {
            var v = Environment.GetEnvironmentVariable(name);
            return string.IsNullOrEmpty(v) ? fallback : v;
        }

        private static async Task<int> Schedule(Invoker invoker)
        {
            try
            {
                var result = await invoker.Invoke(
                    new JsonObject { ["trigger"] = "schedule" }, "",
                    new Dictionary<string, object?> { ["mode"] = "schedule" });
                var node = ToNode(result);
                Console.WriteLine(node is JsonValue v && v.TryGetValue(out string? s) ? s : node?.ToJsonString(Options) ?? "null");
                return 0;
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"Error: {e}");
                return 1;
            }
        }

        private static async Task Handle(HttpContext ctx, Invoker invoker)
        {
            var req = ctx.Request;
            var method = req.Method;
            var path = req.GetEncodedPathAndQuery();
            var status = 500;
            try
            {
                // Knative probe: not passed to the handler
                if (req.Headers.ContainsKey("K-Network-Probe") || req.Headers.ContainsKey("K-Kubelet-Probe"))
                {
                    status = 200;
                    await Send(ctx, 200, new Dictionary<string, string>(), Utf8.GetBytes("ok"));
                    return;
                }

                // CORS preflight
                if (method == "OPTIONS")
                {
                    status = 204;
                    await Send(ctx, 204, new Dictionary<string, string>
                    {
                        ["Access-Control-Allow-Origin"] = "*",
                        ["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
                        ["Access-Control-Allow-Headers"] = "Content-Type, Authorization",
                        ["Access-Control-Max-Age"] = "86400",
                    }, Array.Empty<byte>());
                    return;
                }

                string body;
                using (var reader = new StreamReader(req.Body, Utf8))
                {
                    body = await reader.ReadToEndAsync();
                }

                var headers = new Dictionary<string, string>();
                foreach (var (name, values) in req.Headers)
                {
                    headers[name.ToLowerInvariant()] = string.Join(", ", values.ToArray());
                }
                var context = new Dictionary<string, object?>
                {
                    ["method"] = method,
                    ["path"] = path,
                    ["headers"] = headers,
                };

                object? result;
                try
                {
                    result = await invoker.Invoke(Event(body), body, context);
                }
                catch (Exception e)
                {
                    Console.Error.WriteLine(e);
                    status = 500;
                    var error = new JsonObject { ["error"] = e.Message }.ToJsonString(Options);
                    await Send(ctx, 500, new Dictionary<string, string>
                    {
                        ["Access-Control-Allow-Origin"] = "*",
                        ["Content-Type"] = "application/json",
                    }, Utf8.GetBytes(error));
                    return;
                }
                status = await Respond(ctx, result);
            }
            finally
            {
                Console.WriteLine($"[runr] {method} {path} {status}");
            }
        }

        /// <summary>The request body as the handler's event: a JSON object, else {"body": body}.</summary>
        private static JsonObject Event(string body)
        {
            if (body.Length == 0)
            {
                return new JsonObject();
            }
            try
            {
                if (JsonNode.Parse(body) is JsonObject o)
                {
                    return o;
                }
            }
            catch (JsonException)
            {
                // the raw body below
            }
            return new JsonObject { ["body"] = body };
        }

        private static JsonNode? ToNode(object? value) => value switch
        {
            null => null,
            JsonNode n => n,
            JsonElement e => JsonSerializer.SerializeToNode(e, Options),
            _ => JsonSerializer.SerializeToNode(value, value.GetType(), Options),
        };

        /// <summary>Writes the handler's result; returns the status.</summary>
        private static async Task<int> Respond(HttpContext ctx, object? result)
        {
            var node = ToNode(result);
            var status = 200;
            var body = node;
            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["Access-Control-Allow-Origin"] = "*",
                ["Content-Type"] = "application/json",
            };
            if (node is JsonObject o)
            {
                if (o["statusCode"] is JsonValue sc && sc.GetValueKind() == JsonValueKind.Number
                    && double.TryParse(sc.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var code))
                {
                    status = (int)code;
                }
                if (o["headers"] is JsonObject h)
                {
                    foreach (var (name, value) in h)
                    {
                        headers[name] = value is JsonValue jv && jv.TryGetValue(out string? text) ? text : value?.ToJsonString(Options) ?? "";
                    }
                }
                if (o.ContainsKey("body"))
                {
                    body = o["body"];
                }
            }

            var contentType = headers["Content-Type"];
            var payload = body is JsonValue bv && bv.TryGetValue(out string? s) && !contentType.Contains("application/json")
                ? s
                : body?.ToJsonString(Options) ?? "null";
            if (status < 100 || status > 999)
            {
                status = 500;
            }
            await Send(ctx, status, headers, Utf8.GetBytes(payload));
            return status;
        }

        private static async Task Send(HttpContext ctx, int status, IDictionary<string, string> headers, byte[] body)
        {
            var res = ctx.Response;
            res.StatusCode = status;
            foreach (var (name, value) in headers)
            {
                if (!name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)
                    && !name.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase))
                {
                    res.Headers[name] = value;
                }
            }
            if (body.Length > 0 && status != 204 && status != 304 && status >= 200)
            {
                res.ContentLength = body.Length;
                await res.Body.WriteAsync(body);
            }
        }

        /// <summary>The handler method of the function and how to call it.</summary>
        private sealed class Invoker
        {
            private readonly MethodInfo method;
            private readonly object? target;

            private Invoker(MethodInfo method, object? target)
            {
                this.method = method;
                this.target = target;
            }

            public static Invoker Load(Assembly assembly)
            {
                var handler = Env("RUNR_HANDLER", "Handler");
                var file = Path.GetFileNameWithoutExtension(Env("RUNR_FILENAME", "Function.cs"));

                var types = assembly.GetTypes()
                    .Where(t => t.Namespace != typeof(Host).Namespace && !t.IsDefined(typeof(System.Runtime.CompilerServices.CompilerGeneratedAttribute)))
                    .OrderBy(t => t.Name.Equals(file, StringComparison.OrdinalIgnoreCase) ? 0 : 1)
                    .ThenBy(t => t.FullName, StringComparer.Ordinal)
                    .ToList();
                MethodInfo? found = null;
                foreach (var comparison in new[] { StringComparison.Ordinal, StringComparison.OrdinalIgnoreCase })
                {
                    found = types
                        .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Static | BindingFlags.Instance | BindingFlags.DeclaredOnly)
                            .Where(m => m.Name.Equals(handler, comparison) && m.GetParameters().Length <= 2 && !m.IsGenericMethodDefinition)
                            .OrderByDescending(m => m.GetParameters().Length))
                        .FirstOrDefault();
                    if (found != null)
                    {
                        break;
                    }
                }
                if (found == null)
                {
                    throw new InvalidOperationException(
                        $"handler '{handler}' not found: a public method {handler}(JsonNode? input, IDictionary<string, object?> context) of a class of the function");
                }
                var target = found.IsStatic ? null : Activator.CreateInstance(found.DeclaringType!);
                return new Invoker(found, target);
            }

            public async Task<object?> Invoke(JsonObject input, string body, Dictionary<string, object?> context)
            {
                var parameters = method.GetParameters();
                var args = new object?[parameters.Length];
                for (var i = 0; i < parameters.Length; i++)
                {
                    args[i] = i == 0 ? Convert(input, body, parameters[i].ParameterType) : Convert(context, parameters[i].ParameterType);
                }

                object? result;
                try
                {
                    result = method.Invoke(target, args);
                }
                catch (TargetInvocationException e) when (e.InnerException != null)
                {
                    System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(e.InnerException).Throw();
                    throw;
                }

                switch (result)
                {
                    case Task task:
                        await task;
                        var type = task.GetType();
                        return type.IsGenericType && type.GetProperty("Result") is { } r && r.PropertyType.Name != "VoidTaskResult"
                            ? r.GetValue(task)
                            : null;
                    case ValueTask vt:
                        await vt;
                        return null;
                    default:
                        if (result != null && result.GetType().IsGenericType && result.GetType().GetGenericTypeDefinition() == typeof(ValueTask<>))
                        {
                            var asTask = (Task)result.GetType().GetMethod("AsTask")!.Invoke(result, null)!;
                            await asTask;
                            return asTask.GetType().GetProperty("Result")!.GetValue(asTask);
                        }
                        return result;
                }
            }

            private static object? Convert(JsonObject input, string body, Type type)
            {
                if (type == typeof(string))
                {
                    return body;
                }
                if (type.IsAssignableFrom(typeof(JsonObject)))
                {
                    return input;
                }
                return input.Deserialize(type, Options);
            }

            private static object? Convert(Dictionary<string, object?> context, Type type)
            {
                if (type.IsAssignableFrom(typeof(Dictionary<string, object?>)))
                {
                    return context;
                }
                return JsonSerializer.SerializeToNode(context, Options).Deserialize(type, Options);
            }
        }
    }
}
