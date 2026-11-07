package sh.runr.runtime;

import java.lang.reflect.Array;
import java.lang.reflect.RecordComponent;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * The JSON of the RunR handler server, without a library. parse() reads a document into
 * LinkedHashMap, ArrayList, String, Long (BigInteger beyond it), Double, Boolean and null.
 * write() writes maps, collections and arrays, records (their components), strings, numbers,
 * booleans, characters, enums (their name), Optional and null; any other object as its
 * toString().
 */
public final class Json {
    private static final int MAX_DEPTH = 512;

    private final String s;
    private int i;

    private Json(String s) {
        this.s = s;
    }

    public static Object parse(String text) {
        Json p = new Json(text);
        p.ws();
        Object v = p.value(0);
        p.ws();
        if (p.i != p.s.length()) {
            throw p.error("unexpected data after the value");
        }
        return v;
    }

    public static String write(Object value) {
        StringBuilder b = new StringBuilder();
        write(b, value, 0);
        return b.toString();
    }

    // ── parse ──

    private IllegalArgumentException error(String what) {
        return new IllegalArgumentException("invalid JSON at " + i + ": " + what);
    }

    private void ws() {
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
                return;
            }
            i++;
        }
    }

    private Object value(int depth) {
        if (depth > MAX_DEPTH) {
            throw error("nested too deeply");
        }
        if (i >= s.length()) {
            throw error("unexpected end");
        }
        char c = s.charAt(i);
        switch (c) {
            case '{':
                return object(depth);
            case '[':
                return array(depth);
            case '"':
                return string();
            case 't':
                return literal("true", Boolean.TRUE);
            case 'f':
                return literal("false", Boolean.FALSE);
            case 'n':
                return literal("null", null);
            default:
                if (c == '-' || (c >= '0' && c <= '9')) {
                    return number();
                }
                throw error("unexpected character '" + c + "'");
        }
    }

    private Object literal(String word, Object v) {
        if (!s.startsWith(word, i)) {
            throw error("expected " + word);
        }
        i += word.length();
        return v;
    }

    private Map<String, Object> object(int depth) {
        Map<String, Object> m = new LinkedHashMap<>();
        i++;
        ws();
        if (i < s.length() && s.charAt(i) == '}') {
            i++;
            return m;
        }
        while (true) {
            ws();
            if (i >= s.length() || s.charAt(i) != '"') {
                throw error("expected a key");
            }
            String key = string();
            ws();
            if (i >= s.length() || s.charAt(i) != ':') {
                throw error("expected ':'");
            }
            i++;
            ws();
            m.put(key, value(depth + 1));
            ws();
            if (i >= s.length()) {
                throw error("unexpected end");
            }
            char c = s.charAt(i++);
            if (c == '}') {
                return m;
            }
            if (c != ',') {
                throw error("expected ',' or '}'");
            }
        }
    }

    private List<Object> array(int depth) {
        List<Object> l = new ArrayList<>();
        i++;
        ws();
        if (i < s.length() && s.charAt(i) == ']') {
            i++;
            return l;
        }
        while (true) {
            ws();
            l.add(value(depth + 1));
            ws();
            if (i >= s.length()) {
                throw error("unexpected end");
            }
            char c = s.charAt(i++);
            if (c == ']') {
                return l;
            }
            if (c != ',') {
                throw error("expected ',' or ']'");
            }
        }
    }

    private String string() {
        StringBuilder b = new StringBuilder();
        i++;
        while (true) {
            if (i >= s.length()) {
                throw error("unterminated string");
            }
            char c = s.charAt(i++);
            if (c == '"') {
                return b.toString();
            }
            if (c != '\\') {
                if (c < 0x20) {
                    throw error("control character in a string");
                }
                b.append(c);
                continue;
            }
            if (i >= s.length()) {
                throw error("unterminated string");
            }
            char e = s.charAt(i++);
            switch (e) {
                case '"' -> b.append('"');
                case '\\' -> b.append('\\');
                case '/' -> b.append('/');
                case 'b' -> b.append('\b');
                case 'f' -> b.append('\f');
                case 'n' -> b.append('\n');
                case 'r' -> b.append('\r');
                case 't' -> b.append('\t');
                case 'u' -> {
                    if (i + 4 > s.length()) {
                        throw error("bad unicode escape");
                    }
                    try {
                        b.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                    } catch (NumberFormatException ex) {
                        throw error("bad unicode escape");
                    }
                    i += 4;
                }
                default -> throw error("bad escape '\\" + e + "'");
            }
        }
    }

    private Object number() {
        int start = i;
        boolean decimal = false;
        if (s.charAt(i) == '-') {
            i++;
        }
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c >= '0' && c <= '9') {
                i++;
            } else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
                decimal = true;
                i++;
            } else {
                break;
            }
        }
        String n = s.substring(start, i);
        try {
            if (decimal) {
                return Double.parseDouble(n);
            }
            BigInteger big = new BigInteger(n);
            return big.bitLength() < 64 ? (Object) big.longValue() : big;
        } catch (NumberFormatException ex) {
            throw error("bad number '" + n + "'");
        }
    }

    // ── write ──

    private static void write(StringBuilder b, Object v, int depth) {
        if (depth > MAX_DEPTH) {
            throw new IllegalArgumentException("the value is nested too deeply (a cycle?)");
        }
        if (v == null) {
            b.append("null");
        } else if (v instanceof CharSequence || v instanceof Character) {
            quote(b, v.toString());
        } else if (v instanceof Boolean) {
            b.append(v);
        } else if (v instanceof Double d) {
            b.append(d.isNaN() || d.isInfinite() ? "null" : d.toString());
        } else if (v instanceof Float f) {
            b.append(f.isNaN() || f.isInfinite() ? "null" : f.toString());
        } else if (v instanceof BigDecimal d) {
            b.append(d.toPlainString());
        } else if (v instanceof Number) {
            b.append(v);
        } else if (v instanceof Optional<?> o) {
            write(b, o.orElse(null), depth + 1);
        } else if (v instanceof Enum<?> e) {
            quote(b, e.name());
        } else if (v instanceof Map<?, ?> m) {
            b.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> e : m.entrySet()) {
                if (!first) {
                    b.append(',');
                }
                first = false;
                quote(b, String.valueOf(e.getKey()));
                b.append(':');
                write(b, e.getValue(), depth + 1);
            }
            b.append('}');
        } else if (v instanceof Collection<?> c) {
            b.append('[');
            boolean first = true;
            for (Object e : c) {
                if (!first) {
                    b.append(',');
                }
                first = false;
                write(b, e, depth + 1);
            }
            b.append(']');
        } else if (v.getClass().isArray()) {
            b.append('[');
            int n = Array.getLength(v);
            for (int k = 0; k < n; k++) {
                if (k > 0) {
                    b.append(',');
                }
                write(b, Array.get(v, k), depth + 1);
            }
            b.append(']');
        } else if (v instanceof Record r) {
            b.append('{');
            boolean first = true;
            for (RecordComponent c : r.getClass().getRecordComponents()) {
                if (!first) {
                    b.append(',');
                }
                first = false;
                quote(b, c.getName());
                b.append(':');
                Object value;
                try {
                    c.getAccessor().setAccessible(true);
                    value = c.getAccessor().invoke(r);
                } catch (ReflectiveOperationException | RuntimeException ex) {
                    value = null;
                }
                write(b, value, depth + 1);
            }
            b.append('}');
        } else {
            quote(b, v.toString());
        }
    }

    private static void quote(StringBuilder b, String s) {
        b.append('"');
        for (int k = 0; k < s.length(); k++) {
            char c = s.charAt(k);
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                case '\b' -> b.append("\\b");
                case '\f' -> b.append("\\f");
                default -> {
                    if (c < 0x20 || c == ' ' || c == ' ') {
                        b.append(String.format("\\u%04x", (int) c));
                    } else {
                        b.append(c);
                    }
                }
            }
        }
        b.append('"');
    }
}
