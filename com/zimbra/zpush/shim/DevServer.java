/*
 * Copyright (c) 2025 Z-Push Zimbra Shim contributors
 * Licensed under the MIT License. See LICENSE file for details.
 */
package com.zimbra.zpush.shim;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * Lightweight dev HTTP server (no Zimbra required) that exposes
 * /service/extension/zpush-shim and handles the same action API
 * using CompatCore (mock data).
 */
public class DevServer {
    private static final Gson GSON = new GsonBuilder().disableHtmlEscaping().create();

    public static void main(String[] args) throws Exception {
        int port = 8081;
        String bind = "127.0.0.1";
        for (int i = 0; i < args.length; i++) {
            if ("-p".equals(args[i]) && i + 1 < args.length) {
                port = Integer.parseInt(args[++i]);
            } else if ("-b".equals(args[i]) && i + 1 < args.length) {
                bind = args[++i];
            }
        }
        HttpServer server = HttpServer.create(new InetSocketAddress(bind, port), 0);
        server.createContext("/service/extension/zpush-shim", new ShimHandler());
        server.setExecutor(null);
        System.out.println("DevServer listening on http://" + bind + ":" + port + "/service/extension/zpush-shim");
        server.start();
    }

    static class ShimHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange ex) throws IOException {
            if (!"POST".equalsIgnoreCase(ex.getRequestMethod())) {
                respond(ex, 405, jsonErr("Method Not Allowed"));
                return;
            }
            String body = new String(readAll(ex.getRequestBody()), StandardCharsets.UTF_8);
            Map<String, String> form = parseFormUrlEncoded(body);
            String action = (form.getOrDefault("action", "")).toLowerCase();
            Object out;
            switch (action) {
                case "ping":
                    out = CompatCore.ping();
                    respond(ex, 200, GSON.toJson(out));
                    return;
                case "authenticate":
                    out = CompatCore.authenticate(form.get("username"));
                    respond(ex, 200, GSON.toJson(out));
                    return;
                case "getfolders":
                    out = CompatCore.getFolders();
                    respond(ex, 200, GSON.toJson(out));
                    return;
                case "getmessages":
                    int limit = safeInt(form.get("limit"), 10);
                    out = CompatCore.getMessages(form.get("folderId"), limit);
                    respond(ex, 200, GSON.toJson(out));
                    return;
                case "getmessage":
                    out = CompatCore.getMessage(form.get("messageId"), form.getOrDefault("format", "html"));
                    respond(ex, 200, GSON.toJson(out));
                    return;
                default:
                    respond(ex, 400, jsonErr("Unknown or missing action"));
            }
        }

        private String jsonErr(String msg) {
            return "{\"success\":false,\"error\":\"" + msg.replace("\"", "\\\"") + "\"}";
        }

        private int safeInt(String s, int def) {
            try { return Integer.parseInt(s); } catch (Exception e) { return def; }
        }

        private void respond(HttpExchange ex, int status, String body) throws IOException {
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().set("Content-Type", "application/json; charset=UTF-8");
            ex.sendResponseHeaders(status, bytes.length);
            try (OutputStream os = ex.getResponseBody()) {
                os.write(bytes);
            }
        }

        private Map<String, String> parseFormUrlEncoded(String body) {
            Map<String, String> map = new HashMap<>();
            if (body == null || body.isEmpty()) return map;
            String[] pairs = body.split("&");
            for (String p : pairs) {
                int i = p.indexOf('=');
                String k = i > 0 ? p.substring(0, i) : p;
                String v = i > 0 ? p.substring(i + 1) : "";
                k = urlDecode(k);
                v = urlDecode(v);
                map.put(k, v);
            }
            return map;
        }

        private String urlDecode(String s) {
            try { return URLDecoder.decode(s, "UTF-8"); } catch (Exception e) { return s; }
        }
    }

    // Java 8-compatible helper to read an InputStream fully
    private static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int r;
        while ((r = in.read(buf)) != -1) {
            bos.write(buf, 0, r);
        }
        return bos.toByteArray();
    }
}
