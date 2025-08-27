package com.zimbra.zpush.shim;

import com.zimbra.common.service.ServiceException;
import com.zimbra.cs.extension.ExtensionDispatcherServlet;
import com.zimbra.cs.extension.ZimbraExtension;

/**
 * Zimbra Extension entry point: registers the shim servlet under
 * /service/extension/zpush-shim
 */
public class ZPushShimExtension implements ZimbraExtension {
    public static final String NAME = "zpush-shim";

    @Override
    public String getName() {
        return NAME;
    }

    @Override
    public void init() throws ServiceException {
        // Register HTTP handler at /service/extension/zpush-shim
        ExtensionDispatcherServlet.register(this, new ZPushShimHandler());
    }

    @Override
    public void destroy() {
        ExtensionDispatcherServlet.unregister(this);
    }
}
