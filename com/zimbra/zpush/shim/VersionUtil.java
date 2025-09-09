/*
 * Copyright (c) 2025 Z-Push Zimbra Shim contributors
 * Licensed under the MIT License. See LICENSE file for details.
 */
package com.zimbra.zpush.shim;

import java.io.InputStream;
import java.util.jar.Manifest;
import java.util.jar.Attributes;

final class VersionUtil {
    private VersionUtil() {}

    static String getVersion() {
        // 1) Prefer manifest Implementation-Version exposed via Package API
        try {
            Package p = VersionUtil.class.getPackage();
            if (p != null) {
                String v = p.getImplementationVersion();
                if (v != null && !v.isEmpty()) return v;
            }
        } catch (Throwable ignore) {}

        // 2) Try reading META-INF/MANIFEST.MF directly
        try (InputStream in = VersionUtil.class.getClassLoader().getResourceAsStream("META-INF/MANIFEST.MF")) {
            if (in != null) {
                Manifest mf = new Manifest(in);
                Attributes a = mf.getMainAttributes();
                String v = a.getValue("Implementation-Version");
                if (v != null && !v.isEmpty()) return v;
            }
        } catch (Throwable ignore) {}

        // 3) Fallback for dev server / unit tests
        return "dev";
    }
}

