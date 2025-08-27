package com.zimbra.zpush.shim;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;

import javax.servlet.ServletException;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.*;

/**
 * Minimal, deployment-safe servlet that implements the shim action API.
 *
 * Notes:
 * - This class intentionally does not depend on Zimbra classes so it can compile
 *   in basic environments. Actual Zimbra API integration can be added later or
 *   via a separate class that detects availability at runtime.
 * - For now, it returns mock data that is good enough to validate wiring,
 *   deployment, and the external test harness.
 */
public class ZPushShimCompat extends HttpServlet {
    private static final Gson GSON = new GsonBuilder().disableHtmlEscaping().create();

    private void writeJson(HttpServletResponse resp, Object obj) throws IOException {
        resp.setContentType("application/json; charset=UTF-8");
        PrintWriter w = resp.getWriter();
        w.write(GSON.toJson(obj));
        w.flush();
    }

    private void writeError(HttpServletResponse resp, int status, String message) throws IOException {
        resp.setStatus(status);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("success", false);
        out.put("error", message);
        writeJson(resp, out);
    }

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        String action = Optional.ofNullable(req.getParameter("action")).orElse("").trim().toLowerCase(Locale.ROOT);

        switch (action) {
            case "ping":
                handlePing(resp);
                return;
            case "authenticate":
                handleAuthenticate(req, resp);
                return;
            case "getfolders":
                handleGetFolders(req, resp);
                return;
            case "getmessages":
                handleGetMessages(req, resp);
                return;
            case "getmessage":
                handleGetMessage(req, resp);
                return;
            default:
                writeError(resp, 400, "Unknown or missing action");
        }
    }

    private void handlePing(HttpServletResponse resp) throws IOException {
        writeJson(resp, CompatCore.ping());
    }

    private void handleAuthenticate(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        // Mock implementation: trust provided username/password and return a token
        String username = Optional.ofNullable(req.getParameter("username")).orElse("test@example.com");
        writeJson(resp, CompatCore.authenticate(username));
    }

    private void handleGetFolders(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        // Mock folders that resemble Zimbra views
        writeJson(resp, CompatCore.getFolders());
    }

    // folder() logic moved to CompatCore

    private void handleGetMessages(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String folderId = Optional.ofNullable(req.getParameter("folderId")).orElse("2");
        int limit = parseInt(req.getParameter("limit"), 10);
        writeJson(resp, CompatCore.getMessages(folderId, limit));
    }

    private void handleGetMessage(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String id = Optional.ofNullable(req.getParameter("messageId")).orElse("1000");
        String format = Optional.ofNullable(req.getParameter("format")).orElse("html");
        writeJson(resp, CompatCore.getMessage(id, format));
    }

    private int parseInt(String s, int def) {
        try { return Integer.parseInt(s); } catch (Exception e) { return def; }
    }
}
