package com.zimbra.zpush.shim;

import java.util.*;

/**
 * Core logic for shim actions with mock data. Kept servlet-agnostic so it can
 * be used from both the Zimbra extension (servlet) and the standalone dev server.
 */
public final class CompatCore {
    private CompatCore() {}

    public static Map<String, Object> ping() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("status", "ok");
        out.put("version", "1.0.0");
        out.put("timestamp", System.currentTimeMillis());
        return out;
    }

    public static Map<String, Object> authenticate(String username) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("success", true);
        out.put("authToken", "dev-token-" + UUID.randomUUID());
        out.put("accountId", "dev-account");
        out.put("displayName", username != null ? username : "test@example.com");
        return out;
    }

    public static List<Map<String, Object>> getFolders() {
        List<Map<String, Object>> folders = new ArrayList<>();
        folders.add(folder(1, "USER_ROOT", "", 0, 0));
        folders.add(folder(2, "Inbox", "message", 10, 100));
        folders.add(folder(3, "Sent", "message", 0, 50));
        folders.add(folder(7, "Contacts", "contact", 0, 25));
        folders.add(folder(10, "Calendar", "appointment", 0, 8));
        folders.add(folder(15, "Tasks", "task", 0, 3));
        return folders;
    }

    private static Map<String, Object> folder(int id, String name, String view, int unread, int total) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", id);
        m.put("name", name);
        if (!view.isEmpty()) m.put("view", view);
        m.put("parentId", 1);
        m.put("unread", unread);
        m.put("total", total);
        return m;
    }

    public static List<Map<String, Object>> getMessages(String folderId, int limit) {
        int lim = limit > 0 ? limit : 10;
        List<Map<String, Object>> messages = new ArrayList<>();
        for (int i = 0; i < Math.max(1, lim); i++) {
            int id = 1000 + i;
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", id);
            m.put("subject", "Test message " + i + " in folder " + (folderId != null ? folderId : "2"));
            m.put("from", "boss@example.com");
            m.put("date", System.currentTimeMillis() - (i * 60000L));
            m.put("size", 2048 + i);
            m.put("flags", 0);
            m.put("read", i % 2 == 0);
            messages.add(m);
        }
        return messages;
    }

    public static Map<String, Object> getMessage(String id, String format) {
        Map<String, Object> m = new LinkedHashMap<>();
        String mid = id != null ? id : "1000";
        m.put("id", mid);
        m.put("subject", "Test message " + mid);
        m.put("from", "boss@example.com");
        m.put("to", Arrays.asList("user@example.com"));
        m.put("date", System.currentTimeMillis());
        if ("html".equalsIgnoreCase(format)) {
            m.put("body", "<p>Hello from shim mock HTML.</p>");
        } else {
            m.put("body", "Hello from shim mock plain text.");
        }
        return m;
    }
}

