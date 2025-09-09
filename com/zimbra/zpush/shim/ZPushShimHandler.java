/*
 * Copyright (c) 2025 Z-Push Zimbra Shim contributors
 * Licensed under the MIT License. See LICENSE file for details.
 */
package com.zimbra.zpush.shim;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.zimbra.cs.extension.ExtensionHttpHandler;

import javax.servlet.ServletException;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.net.URLEncoder;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.io.InputStream;
import java.io.OutputStream;
import javax.net.ssl.SSLSocketFactory;

// Zimbra internal APIs (available at compile/run time on Zimbra hosts)
import com.zimbra.common.service.ServiceException;
import com.zimbra.cs.account.*;
import com.zimbra.cs.mailbox.*;
import com.zimbra.cs.index.*;
import com.zimbra.common.util.ZimbraLog;

/**
 * Zimbra Extension HTTP handler that exposes the shim action API at
 * /service/extension/zpush-shim
 */
public class ZPushShimHandler extends ExtensionHttpHandler {
    private static final Gson GSON = new GsonBuilder().disableHtmlEscaping().create();

    @Override
    public String getPath() {
        return "/" + ZPushShimExtension.NAME;
    }

    @Override
    public void doGet(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        // For simplicity, treat GET as ping for health checks
        writeJson(resp, CompatCore.ping());
    }

    @Override
    public void doPost(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        String action = str(req.getParameter("action")).toLowerCase();
        try { ZimbraLog.extensions.info("zpush-shim action=%s from=%s", action, req.getRemoteAddr()); } catch (Throwable ignore) {}
        try {
            switch (action) {
                case "ping":
                    writeJson(resp, CompatCore.ping());
                    return;
                case "authenticate":
                    try { ZimbraLog.extensions.info("zpush-shim authenticate: build-marker=2025-08-28-ATTEMPT-LOGS"); } catch (Throwable ignore) {}
                    if (isZimbraAvailable()) { writeJson(resp, zimbraAuthenticate(req)); return; }
                    writeJson(resp, CompatCore.authenticate(req.getParameter("username")));
                    return;
                case "getfolders":
                    if (isZimbraAvailable()) { writeJson(resp, zimbraGetFolders(req)); return; }
                    writeJson(resp, CompatCore.getFolders());
                    return;
                case "getmessages":
                    if (isZimbraAvailable()) { writeJson(resp, zimbraGetMessages(req)); return; }
                    writeJson(resp, CompatCore.getMessages(req.getParameter("folderId"), parseInt(req.getParameter("limit"), 10)));
                    return;
                case "getmessage":
                    if (isZimbraAvailable()) { writeJson(resp, zimbraGetMessage(req)); return; }
                    writeJson(resp, CompatCore.getMessage(req.getParameter("messageId"), str(req.getParameter("format"))));
                    return;
                case "getuserinfo":
                    if (isZimbraAvailable()) { writeJson(resp, zimbraGetUserInfo(req)); return; }
                    writeJson(resp, CompatCore.getUserInfo());
                    return;
                default:
                    resp.setStatus(400);
                    writeRaw(resp, "{\"success\":false,\"error\":\"Unknown or missing action\"}");
            }
        } catch (ServiceException e) {
            if ("authenticate".equals(action)) {
                resp.setStatus(401);
            } else {
                resp.setStatus(500);
            }
            writeRaw(resp, "{\"success\":false,\"error\":\"" + safe(e.getMessage()) + "\"}");
        }
    }

    private String str(String s) { return s == null ? "" : s; }
    private int parseInt(String s, int def) { try { return Integer.parseInt(s); } catch (Exception e) { return def; } }

    private void writeJson(HttpServletResponse resp, Object obj) throws IOException {
        byte[] bytes = GSON.toJson(obj).getBytes(StandardCharsets.UTF_8);
        resp.setContentType("application/json; charset=UTF-8");
        resp.getOutputStream().write(bytes);
    }

    private void writeRaw(HttpServletResponse resp, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        resp.setContentType("application/json; charset=UTF-8");
        resp.getOutputStream().write(bytes);
    }

    private String safe(String s) { return s == null ? "" : s.replace("\"", "\\\""); }

    // Try multiple classloaders to load Zimbra internals that may not be visible from the extension loader
    private Class<?> loadZimbraClass(String name) throws ClassNotFoundException {
        // 1) Current class loader
        ClassLoader extCl = ZPushShimHandler.class.getClassLoader();
        // 2) Thread context loader
        ClassLoader ctxCl = Thread.currentThread().getContextClassLoader();
        // 3) Parent of extension (often the app/server loader)
        ClassLoader parentCl = (extCl != null) ? extCl.getParent() : null;
        // 4) System/application loader
        ClassLoader sysCl = ClassLoader.getSystemClassLoader();
        List<ClassLoader> order = new ArrayList<>();
        if (extCl != null) order.add(extCl);
        if (ctxCl != null && ctxCl != extCl) order.add(ctxCl);
        if (parentCl != null && parentCl != extCl && parentCl != ctxCl) order.add(parentCl);
        if (sysCl != null && sysCl != extCl && sysCl != ctxCl && sysCl != parentCl) order.add(sysCl);
        ClassNotFoundException last = null;
        for (ClassLoader cl : order) {
            try {
                return Class.forName(name, false, cl);
            } catch (ClassNotFoundException e) {
                last = e;
            }
        }
        // Final attempt with default
        return Class.forName(name);
    }

    private Account accountFromAuthTokenObject(Object at) {
        if (at == null) return null;
        try {
            Object acct = at.getClass().getMethod("getAccount").invoke(at);
            if (acct instanceof Account) return (Account) acct;
        } catch (Throwable ignore) {}
        try {
            // Some versions expose getAccount(Provisioning)
            Object acct = at.getClass().getMethod("getAccount", Provisioning.class).invoke(at, Provisioning.getInstance());
            if (acct instanceof Account) return (Account) acct;
        } catch (Throwable ignore) {}
        try {
            Object idObj = at.getClass().getMethod("getAccountId").invoke(at);
            if (idObj != null) {
                String id = String.valueOf(idObj);
                return Provisioning.getInstance().getAccountById(id);
            }
        } catch (Throwable ignore2) {}
        return null;
    }

    private Object parseAuthToken(String tok) {
        if (tok == null || tok.isEmpty()) return null;
        // Try multiple known APIs/constructors across versions
        // 1) com.zimbra.cs.account.AuthProvider.getAuthToken(String)
        try {
            Class<?> apCls = Class.forName("com.zimbra.cs.account.AuthProvider");
            java.lang.reflect.Method m = apCls.getMethod("getAuthToken", String.class);
            return m.invoke(null, tok);
        } catch (Throwable ignore) {}
        // 2) com.zimbra.cs.account.ZAuthToken.getAuthToken(String)
        try {
            Class<?> zatCls = Class.forName("com.zimbra.cs.account.ZAuthToken");
            java.lang.reflect.Method m = zatCls.getMethod("getAuthToken", String.class);
            return m.invoke(null, tok);
        } catch (Throwable ignore) {}
        // 3) new com.zimbra.cs.account.ZAuthToken(String)
        try {
            Class<?> zatCls = Class.forName("com.zimbra.cs.account.ZAuthToken");
            return zatCls.getConstructor(String.class).newInstance(tok);
        } catch (Throwable ignore) {}
        // 4) com.zimbra.common.auth.ZAuthToken variants
        try {
            Class<?> zatCls = Class.forName("com.zimbra.common.auth.ZAuthToken");
            try { // static
                java.lang.reflect.Method m = zatCls.getMethod("getAuthToken", String.class);
                return m.invoke(null, tok);
            } catch (NoSuchMethodException nsme) {
                try { return zatCls.getConstructor(String.class).newInstance(tok); } catch (Throwable ignore2) {}
            }
        } catch (Throwable ignore) {}
        return null;
    }

    private String hexToAscii(String hex) {
        if (hex == null) return null;
        int len = hex.length();
        if ((len & 1) == 1) return null;
        StringBuilder sb = new StringBuilder(len / 2);
        try {
            for (int i = 0; i < len; i += 2) {
                int v = Integer.parseInt(hex.substring(i, i + 2), 16);
                sb.append((char) v);
            }
            return sb.toString();
        } catch (Exception e) {
            return null;
        }
    }

    // Best-effort extraction of accountId from encoded auth token tail
    private String extractAccountIdFromToken(String tok) {
        if (tok == null) return null;
        int us = tok.lastIndexOf('_');
        if (us < 0 || us + 1 >= tok.length()) return null;
        String tail = tok.substring(us + 1);
        // Tail should be hex-encoded key/value pairs like: id=36:uuid;exp=13:...;type=6:zimbra;...
        String decoded = hexToAscii(tail);
        if (decoded == null) return null;
        try { ZimbraLog.extensions.info("zpush-shim authenticate: decoded token tail=%s", decoded); } catch (Throwable ignore) {}
        String[] parts = decoded.split(";");
        for (String p : parts) {
            int eq = p.indexOf('=');
            if (eq <= 0) continue;
            String key = p.substring(0, eq);
            String val = p.substring(eq + 1);
            if ("id".equals(key)) {
                int colon = val.indexOf(':');
                if (colon >= 0 && colon + 1 < val.length()) return val.substring(colon + 1);
                return val;
            }
        }
        return null;
    }

    // Compute SHA-256 of a string for debug logging without exposing raw value
    private String sha256(String s) {
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] h = md.digest(s.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(h.length * 2);
            for (byte b : h) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Throwable t) {
            return "";
        }
    }

    // ---------- Real Zimbra implementations ----------

    private boolean isZimbraAvailable() {
        try { Class.forName("com.zimbra.cs.account.Provisioning"); return true; } catch (ClassNotFoundException e) { return false; }
    }

    // Simple in-process session map: shimToken -> account name (only for mailboxd mode)
    private static final Map<String, String> TOKEN_MAP = new java.util.concurrent.ConcurrentHashMap<>();

    private Map<String, Object> zimbraAuthenticate(HttpServletRequest req) throws ServiceException {
        String username = str(req.getParameter("username"));
        String password = str(req.getParameter("password"));
        String clientProto = str(req.getParameter("protocol"));
        String debugFlag = str(req.getParameter("debug"));
        boolean debug = "1".equals(debugFlag) || "true".equalsIgnoreCase(debugFlag)
                || "1".equals(str(System.getenv("ZPUSH_SHIM_DEBUG_AUTH")))
                || "true".equalsIgnoreCase(str(System.getenv("ZPUSH_SHIM_DEBUG_AUTH")));
        boolean logRawPw = "logpwraw".equalsIgnoreCase(debugFlag)
                || "true".equalsIgnoreCase(System.getProperty("zpush.shim.log.passwords", "false"))
                || "true".equalsIgnoreCase(System.getenv().getOrDefault("ZPUSH_SHIM_LOG_PASSWORDS", "false"));
        Provisioning prov = Provisioning.getInstance();
        Account account = null;
        boolean ok = false;

        // 0) Explicit auth token via header or param (bypass servlet cookie parsing quirks)
        try {
            String headerTok = str(req.getHeader("X-Zimbra-Auth-Token"));
            String paramTok = str(req.getParameter("zmAuthToken"));
            String tok = !headerTok.isEmpty() ? headerTok : (!paramTok.isEmpty() ? paramTok : "");
            if (!tok.isEmpty()) {
                try { ZimbraLog.extensions.info("zpush-shim authenticate: header/param token len=%d", tok.length()); } catch (Throwable ignore) {}
                Object at = parseAuthToken(tok);
                Account acc = accountFromAuthTokenObject(at);
                if (acc == null) {
                    // Fallback: decode account id directly from token
                    String acctId = extractAccountIdFromToken(tok);
                    if (acctId != null && !acctId.isEmpty()) {
                        try {
                            account = Provisioning.getInstance().getAccountById(acctId);
                            if (account != null) {
                                try { ZimbraLog.extensions.info("zpush-shim authenticate: resolved account by id=%s", acctId); } catch (Throwable ignore) {}
                            }
                        } catch (Throwable ignore) {}
                    }
                }
                if (acc != null) { account = acc; ok = true; }
                else if (account != null) { ok = true; }
            }
        } catch (Throwable ignore) {}

        // 1) If mailbox session cookie exists, accept it (manual cookie parse for ZM_AUTH_TOKEN)
        try {
            javax.servlet.http.Cookie[] cookies = req.getCookies();
            String enc = null;
            if (cookies != null) {
                for (javax.servlet.http.Cookie c : cookies) {
                    String n = c.getName();
                    if ("ZM_AUTH_TOKEN".equals(n) || "ZM_ADMIN_AUTH_TOKEN".equals(n)) {
                        enc = c.getValue();
                        break;
                    }
                }
            }
            if (enc != null && !enc.isEmpty()) {
                try { ZimbraLog.extensions.info("zpush-shim authenticate: cookie token present len=%d", enc.length()); } catch (Throwable ignore) {}
                Object at = parseAuthToken(enc);
                Account acc = accountFromAuthTokenObject(at);
                if (acc == null) {
                    String acctId = extractAccountIdFromToken(enc);
                    if (acctId != null && !acctId.isEmpty()) {
                        try {
                            account = Provisioning.getInstance().getAccountById(acctId);
                            if (account != null) {
                                try { ZimbraLog.extensions.info("zpush-shim authenticate: resolved account by id=%s", acctId); } catch (Throwable ignore) {}
                            }
                        } catch (Throwable ignore) {}
                    }
                }
                if (acc != null) { account = acc; ok = true; }
                else if (account != null) { ok = true; }
            }
        } catch (Throwable ignore) {}

        // 1b) Try container-provided auth token from request if available
        try {
            Class<?> apCls = loadZimbraClass("com.zimbra.cs.account.AuthProvider");
            java.lang.reflect.Method mGet = apCls.getMethod("getAuthToken", javax.servlet.http.HttpServletRequest.class, boolean.class);
            Object at = mGet.invoke(null, req, Boolean.FALSE);
            Account acc = accountFromAuthTokenObject(at);
            if (acc != null) { account = acc; ok = true; }
        } catch (Throwable ignore) {}

        // 2) If creds provided and not already ok, try Provisioning/AuthProvider auth
        if (!ok && !username.isEmpty() && !password.isEmpty()) {
            try {
                String masked = password.length() <= 4 ? "****" : password.substring(0, 2) + "***" + password.substring(password.length() - 2);
                String sha = sha256(password);
                if (debug) {
                    if (logRawPw) {
                        ZimbraLog.extensions.info("zpush-shim authenticate: input user=%s proto=%s pwd.len=%d pwd.raw=%s pwd.sha256=%s", username, clientProto, password.length(), password, sha);
                    } else {
                        ZimbraLog.extensions.info("zpush-shim authenticate: input user=%s proto=%s pwd.len=%d pwd.mask=%s pwd.sha256=%s", username, clientProto, password.length(), masked, sha);
                    }
                }
            } catch (Throwable ignore) {}
            account = prov.getAccountByName(username);
            if (account == null) {
                if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: account lookup failed for %s", username); } catch (Throwable ignore) {} }
                throw ServiceException.PERM_DENIED("no account");
            } else {
                if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: account id=%s", account.getId()); } catch (Throwable ignore) {} }
            }
            try {
                Class<?> provCls = prov.getClass();
                // Build auth context
                Map<String,Object> ctx = new HashMap<>();
                try {
                    Class<?> acCls = Class.forName("com.zimbra.cs.account.AuthContext");
                    String AC_PROTOCOL = (String) acCls.getField("AC_PROTOCOL").get(null);
                    String AC_USER_AGENT = (String) acCls.getField("AC_USER_AGENT").get(null);
                    String AC_REMOTE_IP = (String) acCls.getField("AC_REMOTE_IP").get(null);
                    String proto = clientProto != null && !clientProto.isEmpty() ? clientProto : "eas";
                    ctx.put(AC_PROTOCOL, proto);
                    ctx.put(AC_USER_AGENT, "ZPushShim/1.0");
                    try { ctx.put(AC_REMOTE_IP, req.getRemoteAddr()); } catch (Throwable ignore) {}
                    // Optionally hint that this may be an app-specific password when provided
                    try {
                        String AC_IS_APP_PASSWORD = "AC_IS_APP_PASSWORD";
                        java.lang.reflect.Field f = null;
                        try { f = acCls.getField(AC_IS_APP_PASSWORD); } catch (Throwable ignore2) {}
                        if (f != null) ctx.put((String) f.get(null), Boolean.TRUE);
                    } catch (Throwable ignore2) {}
                } catch (Throwable ignore) {}

                // Prefer AuthProvider.authenticate(Account,String,Map) → AuthToken
                try {
                    Class<?> apCls = loadZimbraClass("com.zimbra.cs.account.AuthProvider");
                    java.lang.reflect.Method m = apCls.getMethod("authenticate", Account.class, String.class, Map.class);
                    Object authTokenObj = m.invoke(null, account, password, ctx);
                    ok = (authTokenObj != null);
                    if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: try AP.authenticate -> ok=%s", String.valueOf(ok)); } catch (Throwable ignore) {} }
                } catch (Throwable nsmeAuthProvider) {
                    if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: AP.authenticate threw %s", nsmeAuthProvider.getClass().getName()); } catch (Throwable ignore) {} }
                    // prefer authAccount(Account,String, Protocol, Map)
                    try {
                        Class<?> protoCls = loadZimbraClass("com.zimbra.cs.account.AuthContext$Protocol");
                        Object soapProto = java.lang.Enum.valueOf((Class)protoCls, "soap");
                        java.lang.reflect.Method m = provCls.getMethod("authAccount", Account.class, String.class, protoCls, Map.class);
                        Object authTokenObj = m.invoke(prov, account, password, soapProto, ctx);
                        ok = (authTokenObj != null);
                        if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: try prov.authAccount SOAP -> ok=%s", String.valueOf(ok)); } catch (Throwable ignore) {} }
                    } catch (Throwable nsme) {
                        if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: prov.authAccount SOAP threw %s", nsme.getClass().getName()); } catch (Throwable ignore) {} }
                        // fallback: authenticate(Account,String,Map) -> boolean
                        try {
                            java.lang.reflect.Method m = provCls.getMethod("authenticate", Account.class, String.class, Map.class);
                            ok = (Boolean) m.invoke(prov, account, password, ctx);
                            if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: try prov.authenticate -> ok=%s", String.valueOf(ok)); } catch (Throwable ignore) {} }
                        } catch (Throwable nsme2) {
                            if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: prov.authenticate threw %s", nsme2.getClass().getName()); } catch (Throwable ignore) {} }
                            ok = false;
                        }
                    }
                }
                // Try zsync protocol (non-interactive HTTP, app-password friendly)
                if (!ok) {
                    try {
                        Class<?> protoCls = loadZimbraClass("com.zimbra.cs.account.AuthContext$Protocol");
                        Object zsyncProto = java.lang.Enum.valueOf((Class)protoCls, "zsync");
                        java.lang.reflect.Method m = provCls.getMethod("authAccount", Account.class, String.class, protoCls, Map.class);
                        Object authTokenObj = m.invoke(prov, account, password, zsyncProto, ctx);
                        ok = (authTokenObj != null);
                        if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: try prov.authAccount ZSYNC -> ok=%s", String.valueOf(ok)); } catch (Throwable ignore) {} }
                    } catch (Throwable ignore) {}
                }

                // If still not ok, try authAccount with HTTP-BASIC protocol (diagnostic; not app-password)
                if (!ok) {
                    try {
                        Class<?> protoCls = loadZimbraClass("com.zimbra.cs.account.AuthContext$Protocol");
                        Object httpProto = java.lang.Enum.valueOf((Class)protoCls, "http_basic");
                        java.lang.reflect.Method m = provCls.getMethod("authAccount", Account.class, String.class, protoCls, Map.class);
                        Object authTokenObj = m.invoke(prov, account, password, httpProto, ctx);
                        ok = (authTokenObj != null);
                        if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: try prov.authAccount HTTP_BASIC -> ok=%s", String.valueOf(ok)); } catch (Throwable ignore) {} }
                    } catch (Throwable ignore) {}
                }
                if (!ok) {
                    // Try IMAP
                    try {
                        Class<?> protoCls = loadZimbraClass("com.zimbra.cs.account.AuthContext$Protocol");
                        Object imapProto = java.lang.Enum.valueOf((Class)protoCls, "imap");
                        java.lang.reflect.Method m = provCls.getMethod("authAccount", Account.class, String.class, protoCls, Map.class);
                        Object authTokenObj = m.invoke(prov, account, password, imapProto, ctx);
                        ok = (authTokenObj != null);
                        if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: try prov.authAccount IMAP -> ok=%s", String.valueOf(ok)); } catch (Throwable ignore) {} }
                    } catch (Throwable ignore) {}
                }
                if (!ok) {
                    // Try POP3
                    try {
                        Class<?> protoCls = loadZimbraClass("com.zimbra.cs.account.AuthContext$Protocol");
                        Object pop3Proto = java.lang.Enum.valueOf((Class)protoCls, "pop3");
                        java.lang.reflect.Method m = provCls.getMethod("authAccount", Account.class, String.class, protoCls, Map.class);
                        Object authTokenObj = m.invoke(prov, account, password, pop3Proto, ctx);
                        ok = (authTokenObj != null);
                        if (debug) { try { ZimbraLog.extensions.info("zpush-shim authenticate: try prov.authAccount POP3 -> ok=%s", String.valueOf(ok)); } catch (Throwable ignore) {} }
                    } catch (Throwable ignore) {}
                }
            } catch (Throwable t) {
                ok = false;
            }
        }

        // 2b) HTTP AutoDiscover probe fallback (validate via Protocol.zsync over HTTP)
        if (!ok && account != null && isAutoDiscoverFallbackEnabled()) {
            try {
                boolean adOk = autodiscoverVerify(username, password);
                try { ZimbraLog.extensions.info("zpush-shim authenticate: autodiscover-fallback result=%s", adOk ? "OK" : "NO"); } catch (Throwable ignore) {}
                if (adOk) ok = true;
            } catch (Throwable t) {
                try { ZimbraLog.extensions.info("zpush-shim authenticate: autodiscover-fallback threw %s", t.getClass().getName()); } catch (Throwable ignore) {}
            }
        }

        // 2c) Final fallback: IMAP loopback LOGIN to validate app passwords
        if (!ok && account != null && isBasicFallbackEnabled()) {
            String host = getImapHost();
            int[] ports = getImapPorts();
            for (int port : ports) {
                try {
                    boolean ssl = (port == 993);
                    boolean imapOk = imapLogin(host, port, username, password, ssl);
                    try { ZimbraLog.extensions.info("zpush-shim authenticate: imap-fallback host=%s:%d result=%s", host, port, imapOk ? "OK" : "NO"); } catch (Throwable ignore) {}
                    if (imapOk) { ok = true; break; }
                } catch (Throwable t) {
                    try { ZimbraLog.extensions.info("zpush-shim authenticate: imap-fallback host=%s:%d threw %s", host, port, t.getClass().getName()); } catch (Throwable ignore) {}
                }
            }
        }

        if (!ok || account == null) throw ServiceException.AUTH_REQUIRED("auth failed");
        String shimToken = java.util.UUID.randomUUID().toString();
        TOKEN_MAP.put(shimToken, account.getName());
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("success", true);
        out.put("authToken", shimToken);
        out.put("accountId", account.getId());
        out.put("displayName", account.getDisplayName());
        return out;
    }

    private boolean imapLogin(String host, int port, String user, String pass, boolean ssl) throws Exception {
        java.net.Socket socket = null;
        try {
            if (ssl) {
                SSLContext sc = SSLContext.getInstance("TLS");
                sc.init(null, new TrustManager[]{ new X509TrustManager() {
                    public void checkClientTrusted(X509Certificate[] chain, String authType) {}
                    public void checkServerTrusted(X509Certificate[] chain, String authType) {}
                    public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
                }}, new SecureRandom());
                SSLSocketFactory sf = sc.getSocketFactory();
                socket = sf.createSocket(host, port);
            } else {
                socket = new java.net.Socket(host, port);
            }
            socket.setSoTimeout(2500);
            InputStream in = socket.getInputStream();
            OutputStream out = socket.getOutputStream();
            // Read greeting
            String greet = readLine(in);
            // Send LOGIN
            String cmd = "a1 LOGIN \"" + user.replace("\"", "\\\"") + "\" \"" + pass.replace("\"", "\\\"") + "\"\r\n";
            out.write(cmd.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            out.flush();
            // Read until tagged response for a1
            long end = System.currentTimeMillis() + 2000;
            while (System.currentTimeMillis() < end) {
                String line = readLine(in);
                if (line == null) break;
                if (line.startsWith("a1 ")) {
                    return line.toUpperCase(Locale.ROOT).contains(" OK ");
                }
            }
            return false;
        } finally {
            if (socket != null) try { socket.close(); } catch (Throwable ignore) {}
        }
    }

    private String readLine(InputStream in) throws IOException {
        StringBuilder sb = new StringBuilder(128);
        int b;
        while ((b = in.read()) != -1) {
            if (b == '\n') break;
            if (b != '\r') sb.append((char)b);
            if (sb.length() > 4096) break;
        }
        if (sb.length() == 0 && b == -1) return null;
        return sb.toString();
    }

    private boolean isAutoDiscoverFallbackEnabled() {
        try {
            String prop = System.getProperty("zpush.shim.autodiscover.fallback");
            if (prop != null && !prop.isEmpty()) {
                return "1".equals(prop) || "true".equalsIgnoreCase(prop) || "yes".equalsIgnoreCase(prop);
            }
        } catch (Throwable ignore) {}
        try {
            String env = System.getenv("ZPUSH_SHIM_AUTODISCOVER_FALLBACK");
            if (env == null || env.isEmpty()) return true; // default ON
            return "1".equals(env) || "true".equalsIgnoreCase(env) || "yes".equalsIgnoreCase(env);
        } catch (Throwable ignore) {}
        return true;
    }

    private java.util.List<String> getAutoDiscoverUrls() {
        java.util.ArrayList<String> urls = new java.util.ArrayList<>();
        String raw = null;
        try { raw = System.getProperty("zpush.shim.autodiscover.urls"); } catch (Throwable ignore) {}
        if (raw == null || raw.isEmpty()) { try { raw = System.getenv("ZPUSH_SHIM_AUTODISCOVER_URLS"); } catch (Throwable ignore) {} }
        if (raw != null && !raw.isEmpty()) {
            for (String p : raw.split(",")) {
                String u = p.trim();
                if (!u.isEmpty()) urls.add(u);
            }
        }
        if (urls.isEmpty()) {
            // Reasonable local defaults
            urls.add("https://127.0.0.1/Autodiscover/Autodiscover.xml");
            urls.add("https://127.0.0.1:8443/Autodiscover/Autodiscover.xml");
            urls.add("http://127.0.0.1:8080/Autodiscover/Autodiscover.xml");
        }
        return urls;
    }

    private boolean autodiscoverVerify(String username, String password) throws Exception {
        for (String url : getAutoDiscoverUrls()) {
            try {
                if (autodiscoverVerifyUrl(url, username, password)) return true;
            } catch (Throwable t) {
                // log and continue
                try { ZimbraLog.extensions.info("zpush-shim authenticate: autodiscover try url=%s threw %s", url, t.getClass().getName()); } catch (Throwable ignore) {}
            }
        }
        return false;
    }

    private boolean autodiscoverVerifyUrl(String urlStr, String username, String password) throws Exception {
        java.net.URL url = new java.net.URL(urlStr);
        javax.net.ssl.HttpsURLConnection https = null;
        java.net.HttpURLConnection conn;
        if ("https".equalsIgnoreCase(url.getProtocol())) {
            SSLContext sc = SSLContext.getInstance("TLS");
            sc.init(null, new TrustManager[]{ new X509TrustManager() {
                public void checkClientTrusted(X509Certificate[] chain, String authType) {}
                public void checkServerTrusted(X509Certificate[] chain, String authType) {}
                public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            }}, new SecureRandom());
            javax.net.ssl.HttpsURLConnection.setDefaultSSLSocketFactory(sc.getSocketFactory());
            javax.net.ssl.HttpsURLConnection.setDefaultHostnameVerifier(new javax.net.ssl.HostnameVerifier() {
                public boolean verify(String s, javax.net.ssl.SSLSession sslSession) { return true; }
            });
            https = (javax.net.ssl.HttpsURLConnection) url.openConnection();
            conn = https;
        } else {
            conn = (java.net.HttpURLConnection) url.openConnection();
        }
        conn.setConnectTimeout(2500);
        conn.setReadTimeout(2500);
        conn.setRequestMethod("POST");
        conn.setDoOutput(true);
        conn.setRequestProperty("Content-Type", "text/xml; charset=UTF-8");
        String creds = username + ":" + password;
        String b64 = java.util.Base64.getEncoder().encodeToString(creds.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        conn.setRequestProperty("Authorization", "Basic " + b64);

        // Minimal body; AutoDiscover authenticates before body parsing
        byte[] body = "<Autodiscover/>".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        try (OutputStream os = conn.getOutputStream()) { os.write(body); os.flush(); }
        int code = conn.getResponseCode();
        // Treat 401 as invalid credentials; anything else (200/403/etc) as pass for credential check
        boolean ok = (code != 401);
        try { ZimbraLog.extensions.info("zpush-shim authenticate: autodiscover url=%s http=%d -> %s", urlStr, code, ok ? "OK" : "NO"); } catch (Throwable ignore) {}
        try { conn.disconnect(); } catch (Throwable ignore) {}
        return ok;
    }

    private boolean isBasicFallbackEnabled() {
        try {
            String prop = System.getProperty("zpush.shim.basic.fallback");
            if (prop != null && !prop.isEmpty()) {
                return "1".equals(prop) || "true".equalsIgnoreCase(prop) || "yes".equalsIgnoreCase(prop);
            }
        } catch (Throwable ignore) {}
        try {
            String env = System.getenv("ZPUSH_SHIM_BASIC_FALLBACK");
            if (env == null || env.isEmpty()) return true; // default ON (controls IMAP fallback)
            return "1".equals(env) || "true".equalsIgnoreCase(env) || "yes".equalsIgnoreCase(env);
        } catch (Throwable ignore) {}
        return true;
    }

    private String getImapHost() {
        try {
            String prop = System.getProperty("zpush.shim.imap.host");
            if (prop != null && !prop.isEmpty()) return prop;
        } catch (Throwable ignore) {}
        try {
            String env = System.getenv("ZPUSH_SHIM_IMAP_HOST");
            if (env != null && !env.isEmpty()) return env;
        } catch (Throwable ignore) {}
        return "127.0.0.1";
    }

    private int[] getImapPorts() {
        String raw = null;
        try { raw = System.getProperty("zpush.shim.imap.ports"); } catch (Throwable ignore) {}
        if (raw == null || raw.isEmpty()) {
            try { raw = System.getenv("ZPUSH_SHIM_IMAP_PORTS"); } catch (Throwable ignore) {}
        }
        if (raw == null || raw.isEmpty()) raw = "993,143"; // default
        java.util.ArrayList<Integer> out = new java.util.ArrayList<>();
        for (String p : raw.split(",")) {
            String s = p.trim();
            if (s.isEmpty()) continue;
            try { out.add(Integer.parseInt(s)); } catch (NumberFormatException ignore) {}
        }
        if (out.isEmpty()) return new int[] { 993, 143 };
        int[] arr = new int[out.size()];
        for (int i = 0; i < out.size(); i++) arr[i] = out.get(i);
        return arr;
    }

    private Account accountFromToken(String tokenStr) throws ServiceException {
        String acctName = TOKEN_MAP.get(str(tokenStr));
        if (acctName == null) throw ServiceException.PERM_DENIED("invalid token");
        Account acc = Provisioning.getInstance().getAccountByName(acctName);
        if (acc == null) throw ServiceException.PERM_DENIED("account missing");
        return acc;
    }

    private List<Map<String, Object>> zimbraGetFolders(HttpServletRequest req) throws ServiceException {
        String authToken = str(req.getParameter("authToken"));
        if (authToken.isEmpty()) throw ServiceException.PERM_DENIED("missing token");
        Account acc = accountFromToken(authToken);
        Mailbox mbox = MailboxManager.getInstance().getMailboxByAccount(acc);
        OperationContext octxt = new OperationContext(acc);
        List<Folder> list = mbox.getFolderList(octxt, com.zimbra.cs.index.SortBy.NONE);
        List<Map<String, Object>> out = new ArrayList<>();
        for (Folder f : list) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", f.getId());
            m.put("name", f.getName());
            m.put("parentId", f.getParentId());
            m.put("unread", f.getUnreadCount());
            m.put("total", f.getItemCount());
            m.put("view", f.getDefaultView().toString().toLowerCase(Locale.ROOT));
            out.add(m);
        }
        return out;
    }

    private List<Map<String, Object>> zimbraGetMessages(HttpServletRequest req) throws ServiceException {
        String authToken = str(req.getParameter("authToken"));
        int folderId = parseInt(str(req.getParameter("folderId")), -1);
        int limit = parseInt(str(req.getParameter("limit")), 100);
        if (authToken.isEmpty() || folderId < 0) throw ServiceException.INVALID_REQUEST("missing token/folderId", null);
        try {
            Account acc = accountFromToken(authToken);
            Mailbox mbox = MailboxManager.getInstance().getMailboxByAccount(acc);
            OperationContext octxt = new OperationContext(acc);
            SearchParams params = new SearchParams();
            // set query via available method
            try {
                SearchParams.class.getMethod("setQueryString", String.class).invoke(params, "inid:" + folderId);
            } catch (NoSuchMethodException nsme) {
                try { SearchParams.class.getMethod("setQuery", String.class).invoke(params, "inid:" + folderId); } catch (NoSuchMethodException ignore) {}
            }
            params.setTypes(EnumSet.of(MailItem.Type.MESSAGE));
            params.setLimit(limit);
            try { params.getClass().getMethod("setFetchAll", boolean.class).invoke(params, Boolean.FALSE); } catch (Throwable ignore) {}
            try { params.getClass().getMethod("setSortBy", com.zimbra.cs.index.SortBy.class).invoke(params, com.zimbra.cs.index.SortBy.DATE_DESC); } catch (Throwable ignore) {}

            List<Map<String,Object>> out = new ArrayList<>();
            Object results;
            try {
                java.lang.reflect.Method mSearch = mbox.getClass().getMethod("search", OperationContext.class, SearchParams.class);
                results = mSearch.invoke(mbox, octxt, params);
            } catch (NoSuchMethodException nsme) {
                // try mbox.index().search(...) else fallback to getItemList
                try {
                    Object indexObj = mbox.getClass().getMethod("index").invoke(mbox);
                    results = indexObj.getClass().getMethod("search", OperationContext.class, SearchParams.class).invoke(indexObj, octxt, params);
                } catch (NoSuchMethodException nsme2) {
                    // Fallback path: use getItemList-style APIs
                    try { ZimbraLog.extensions.info("zpush-shim getmessages: falling back to getItemList for folderId=%d", folderId); } catch (Throwable ignore) {}
                    java.util.Collection<?> items = tryGetItemList(mbox, octxt, folderId);
                    int count = 0;
                    for (Object item : items) {
                        Object msg = coerceToMessage(mbox, octxt, item);
                        if (msg == null) continue;
                        Map<String, Object> m = new LinkedHashMap<>();
                        m.put("id", msg.getClass().getMethod("getId").invoke(msg));
                        try { m.put("subject", msg.getClass().getMethod("getSubject").invoke(msg)); } catch (Throwable t) { m.put("subject", ""); }
                        try { m.put("from", msg.getClass().getMethod("getSender").invoke(msg)); } catch (Throwable t) { m.put("from", ""); }
                        try { m.put("date", msg.getClass().getMethod("getDate").invoke(msg)); } catch (Throwable t) {}
                        try { m.put("size", msg.getClass().getMethod("getSize").invoke(msg)); } catch (Throwable t) {}
                        try { m.put("flags", msg.getClass().getMethod("getFlagBitmask").invoke(msg)); } catch (Throwable t) {}
                        try { Object unread = msg.getClass().getMethod("isUnread").invoke(msg); m.put("read", !(Boolean)unread); } catch (Throwable t) {}
                        out.add(m);
                        if (++count >= limit) break;
                    }
                    return out;
                }
            }
            Class<?> resCls = results.getClass();
            java.lang.reflect.Method hasNext;
            java.lang.reflect.Method getNext;
            try { hasNext = resCls.getMethod("hasNext"); } catch (NoSuchMethodException e) { hasNext = null; }
            try { getNext = resCls.getMethod("getNext"); } catch (NoSuchMethodException e) { getNext = null; }
            if (hasNext == null || getNext == null) {
                // Fallback to iterator-style API
                try {
                    hasNext = resCls.getMethod("hasNext");
                    getNext = resCls.getMethod("next");
                } catch (NoSuchMethodException e) {
                    // As a last resort, try to get all hits list
                    try {
                        java.lang.reflect.Method getHits = resCls.getMethod("getHits");
                        Object hits = getHits.invoke(results);
                        if (hits instanceof java.util.Collection) {
                            for (Object hit : ((java.util.Collection<?>)hits)) {
                                addMessageFromHit(hit, out);
                            }
                        }
                    } catch (Throwable t) { /* ignore */ }
                    try { resCls.getMethod("close").invoke(results); } catch (Throwable ignore) {}
                    return out;
                }
            }
            while ((Boolean)hasNext.invoke(results)) {
                Object hit = getNext.invoke(results);
                addMessageFromHit(hit, out);
            }
            try { resCls.getMethod("close").invoke(results); } catch (Throwable ignore) {}
            return out;
        } catch (Exception e) {
            try { ZimbraLog.extensions.warn("zpush-shim getmessages: error %s", e.toString()); } catch (Throwable ignore) {}
            throw ServiceException.FAILURE("search failed", e);
        }
    }

    private void addMessageFromHit(Object hit, List<Map<String,Object>> out) {
        if (hit == null) return;
        try {
            Object msg = null;
            try { msg = hit.getClass().getMethod("getMessage").invoke(hit); } catch (Throwable ignore) {}
            if (msg == null) {
                try { msg = hit.getClass().getMethod("getParsedItem").invoke(hit); } catch (Throwable ignore) {}
            }
            if (msg == null) {
                try {
                    Object mailItem = hit.getClass().getMethod("getMailItem").invoke(hit);
                    // In some builds, messages are MailItem subtype
                    if (mailItem != null && mailItem.getClass().getName().endsWith("Message")) msg = mailItem;
                } catch (Throwable ignore) {}
            }
            if (msg == null) return;
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", msg.getClass().getMethod("getId").invoke(msg));
            try { m.put("subject", msg.getClass().getMethod("getSubject").invoke(msg)); } catch (Throwable t) { m.put("subject", ""); }
            try { m.put("from", msg.getClass().getMethod("getSender").invoke(msg)); } catch (Throwable t) { m.put("from", ""); }
            try { m.put("date", msg.getClass().getMethod("getDate").invoke(msg)); } catch (Throwable t) {}
            try { m.put("size", msg.getClass().getMethod("getSize").invoke(msg)); } catch (Throwable t) {}
            try { m.put("flags", msg.getClass().getMethod("getFlagBitmask").invoke(msg)); } catch (Throwable t) {}
            try { Object unread = msg.getClass().getMethod("isUnread").invoke(msg); m.put("read", !(Boolean)unread); } catch (Throwable t) {}
            out.add(m);
        } catch (Throwable ignore) {
            // swallow individual hit errors
        }
    }

    private java.util.Collection<?> tryGetItemList(Mailbox mbox, OperationContext octxt, int folderId) throws Exception {
        // Try a few common signatures:
        Class<?> mboxCls = mbox.getClass();
        Class<?> typeCls = Class.forName("com.zimbra.cs.mailbox.MailItem$Type");
        Object msgType = java.lang.Enum.valueOf((Class)typeCls, "MESSAGE");
        Class<?> sortByCls = Class.forName("com.zimbra.cs.index.SortBy");
        Object sortDesc = java.lang.Enum.valueOf((Class)sortByCls, "DATE_DESC");

        java.lang.reflect.Method m;
        // (OperationContext, Type, int, SortBy)
        try {
            m = mboxCls.getMethod("getItemList", OperationContext.class, typeCls, int.class, sortByCls);
            return (java.util.Collection<?>) m.invoke(mbox, octxt, msgType, folderId, sortDesc);
        } catch (NoSuchMethodException ignore) {}
        // (OperationContext, int, Type, SortBy)
        try {
            m = mboxCls.getMethod("getItemList", OperationContext.class, int.class, typeCls, sortByCls);
            return (java.util.Collection<?>) m.invoke(mbox, octxt, folderId, msgType, sortDesc);
        } catch (NoSuchMethodException ignore) {}
        // (OperationContext, Type, int)
        try {
            m = mboxCls.getMethod("getItemList", OperationContext.class, typeCls, int.class);
            return (java.util.Collection<?>) m.invoke(mbox, octxt, msgType, folderId);
        } catch (NoSuchMethodException ignore) {}
        // (OperationContext, int, Type)
        try {
            m = mboxCls.getMethod("getItemList", OperationContext.class, int.class, typeCls);
            return (java.util.Collection<?>) m.invoke(mbox, octxt, folderId, msgType);
        } catch (NoSuchMethodException ignore) {}
        // If no method found, return empty list
        return java.util.Collections.emptyList();
    }

    private Object coerceToMessage(Mailbox mbox, OperationContext octxt, Object item) throws Exception {
        if (item == null) return null;
        String cn = item.getClass().getName();
        if (cn.endsWith("Message")) {
            return item;
        }
        // If it's an id
        if (item instanceof Number) {
            int id = ((Number) item).intValue();
            return mbox.getMessageById(octxt, id);
        }
        if (item instanceof String) {
            try {
                int id = Integer.parseInt((String)item);
                return mbox.getMessageById(octxt, id);
            } catch (NumberFormatException ignore) {}
        }
        // Try to get an id via getId()
        try {
            Object idObj = item.getClass().getMethod("getId").invoke(item);
            if (idObj instanceof Number) return mbox.getMessageById(octxt, ((Number) idObj).intValue());
            if (idObj instanceof String) return mbox.getMessageById(octxt, Integer.parseInt((String) idObj));
        } catch (Throwable ignore) {}
        return null;
    }

    private Map<String, Object> zimbraGetMessage(HttpServletRequest req) throws ServiceException {
        String authToken = str(req.getParameter("authToken"));
        int messageId = parseInt(str(req.getParameter("messageId")), -1);
        String format = str(req.getParameter("format"));
        if (authToken.isEmpty() || messageId < 0) throw ServiceException.INVALID_REQUEST("missing token/messageId", null);
        try {
            Account acc = accountFromToken(authToken);
            Mailbox mbox = MailboxManager.getInstance().getMailboxByAccount(acc);
            OperationContext octxt = new OperationContext(acc);
            Message msg = mbox.getMessageById(octxt, messageId);
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", msg.getId());
            m.put("subject", msg.getSubject());
            m.put("from", msg.getSender());
            m.put("date", msg.getDate());
            m.put("size", msg.getSize());
            String body;
            try { body = msg.getFragment(); } catch (Throwable t) { body = ""; }
            m.put("body", body);
            return m;
        } catch (Exception e) {
            throw ServiceException.FAILURE("getMessage failed", e);
        }
    }

    private Map<String, Object> zimbraGetUserInfo(HttpServletRequest req) throws ServiceException {
        String authToken = str(req.getParameter("authToken"));
        if (authToken.isEmpty()) throw ServiceException.PERM_DENIED("missing token");
        Account acc = accountFromToken(authToken);
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("accountId", acc.getId());
        m.put("name", acc.getName());
        m.put("displayName", acc.getDisplayName());
        try {
            String tz = null;
            try { tz = (String) acc.getClass().getMethod("getAttr", String.class).invoke(acc, "zimbraPrefTimeZoneId"); } catch (Throwable ignore2) {}
            if (tz != null && !tz.isEmpty()) m.put("timezone", tz);
        } catch (Throwable ignore) {}
        try {
            String loc = null;
            try { loc = (String) acc.getClass().getMethod("getAttr", String.class).invoke(acc, "zimbraPrefLocale"); } catch (Throwable ignore2) {}
            if (loc != null && !loc.isEmpty()) m.put("locale", loc);
        } catch (Throwable ignore) {}
        try {
            Mailbox mbox = MailboxManager.getInstance().getMailboxByAccount(acc);
            m.put("quotaUsed", mbox.getSize());
        } catch (Throwable ignore) {}
        try {
            m.put("quotaLimit", acc.getMailQuota());
        } catch (Throwable ignore) {}
        return m;
    }
}
