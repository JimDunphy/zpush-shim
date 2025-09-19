# Z-Push Nginx Routing Configuration

## Overview

This configuration routes Microsoft ActiveSync and Autodiscover requests from Zimbra's nginx proxy to the Z-Push container instead of Zimbra's built-in handlers. This enables the zpush-shim integration for 20-60x performance improvement.

## What We Learned from Zimbra's Templates

Zimbra's existing ActiveSync templates have sophisticated features:

1. **Multi-server cluster support** using `${web.upstream.target}` variables
2. **Complex redirect handling** for multi-mailbox environments  
3. **Proper timeouts and buffering** for ActiveSync long polling
4. **EWS/Exchange detection** with conditional upstream routing
5. **Virtual hosting support** with proper header forwarding

Our Z-Push routing preserves these patterns while redirecting to the Z-Push container.

## Files Created/Modified

### 1. New Include File: `/opt/zimbra/config/nginx/includes/zpush-activesync.conf`

This file contains:
- **Upstream definition** for Z-Push container (port 9073)
- **ActiveSync location block** routing `/Microsoft-Server-ActiveSync` to Z-Push
- **Autodiscover location block** routing `/autodiscover` to Z-Push
- **Proper headers** for ActiveSync/Z-Push compatibility
- **Zimbra-style redirect handling** for multi-server compatibility

### 2. Modified Templates

**Backups created:**
- `nginx.conf.web.https.template.orig` - Original HTTPS template
- `nginx.conf.web.http.template.orig` - Original HTTP template

**Templates modified:**
- `nginx.conf.web.https.template` - HTTPS server blocks
- `nginx.conf.web.http.template` - HTTP server blocks

**Changes made:**
- Original ActiveSync/Autodiscover blocks commented out (not deleted)
- Added include line for `zpush-activesync.conf`
- Clear comments indicating what was changed and why

## Key Features of Our Configuration

### 1. Safe Rollback
- Original blocks commented out, not deleted
- Easy to restore by uncommenting and removing include
- Original templates backed up with `.orig` extension

### 2. Zimbra Compatibility
- Preserves Zimbra's redirect handling patterns
- Uses same timeout variables (`${web.upstream.polling.timeout}`)
- Maintains virtual hosting support
- Follows Zimbra's header forwarding patterns

### 3. Z-Push Optimization
- Proper headers for ActiveSync compatibility
- Large body sizes for attachments (50MB for ActiveSync, 10MB for Autodiscover)  
- Request buffering disabled for streaming
- Authorization header forwarding for authentication

### 4. Production Ready
- Upstream with health checks and keepalive
- Proper error handling
- Same location priorities as original (^~ prefix)

## Deployment Steps

### 1. Copy Files to Zimbra Host
```bash
# Copy our modified templates and include file
rsync -av /home/jad/openai/zimbra74/nginx/opt/zimbra/config/nginx/ /opt/zimbra/config/nginx/
```

### 2. Restart Zimbra Proxy
```bash
su - zimbra -c "zmproxyctl restart"
```

### 3. Verify Configuration
```bash
# Check nginx config syntax
su - zimbra -c "zmproxyctl check"

# Test ActiveSync endpoint
curl -k https://your-zimbra-server/Microsoft-Server-ActiveSync
# Should get response from Z-Push, not "Extension HTTP handler not found"
```

## Testing the Configuration

### 1. ActiveSync Test
```bash
# Should route to Z-Push container on port 9073
curl -k -H "User-Agent: Apple-iPhone7C2/1202.466" \\
    https://your-zimbra-server/Microsoft-Server-ActiveSync
```

### 2. Autodiscover Test  
```bash
# Should route to Z-Push for autodiscover
curl -k -X POST \\
    -H "Content-Type: text/xml" \\
    https://your-zimbra-server/autodiscover/autodiscover.xml
```

### 3. Regular Zimbra Services
```bash
# Should still work normally (routed to Zimbra)
curl -k https://your-zimbra-server/
curl -k https://your-zimbra-server/service/soap/
```

## Rollback Procedure

If you need to revert to original Zimbra ActiveSync handling:

### 1. Restore Original Templates
```bash
cd /opt/zimbra/config/nginx/templates/
cp nginx.conf.web.https.template.orig nginx.conf.web.https.template
cp nginx.conf.web.http.template.orig nginx.conf.web.http.template
```

### 2. Restart Proxy
```bash
su - zimbra -c "zmproxyctl restart"
```

### 3. Remove Include File (Optional)
```bash
rm /opt/zimbra/config/nginx/includes/zpush-activesync.conf
```

## Advanced: Alternative Deployment Using manage.sh

The project's `manage.sh` script has automated functions that can achieve similar results:

```bash
# Auto-inject (less safe, harder to review)
./manage.sh --patch-templates-auto

# Manual approach (safer, easier to customize)  
./manage.sh --patch-templates
# Then manually edit templates to add your specific configuration
```

Our manual approach is safer because:
- You can review exactly what changes before applying
- Comments clearly show what was modified
- Easy rollback with clear backup files
- Can customize the configuration for your specific needs

## Configuration Notes

### Port Configuration
- Z-Push container runs on port 9073 (configurable in docker-compose.yml)
- If you change the port, update `zpush-activesync.conf` upstream definition

### Multi-Server Environments  
- Current configuration assumes Z-Push runs on same host as nginx proxy
- For multi-server setups, modify upstream server addresses in `zpush-activesync.conf`
- Consider adding multiple upstream servers for load balancing

### SSL/TLS
- Configuration handles both HTTP and HTTPS templates
- Z-Push container runs HTTP internally (normal for proxy setups)
- Nginx handles SSL termination and forwards to Z-Push as HTTP

## Monitoring

Watch nginx logs for routing verification:
```bash
tail -f /opt/zimbra/log/nginx.access.log | grep -E "(Microsoft-Server-ActiveSync|autodiscover)"
```

Watch Z-Push logs for successful requests:
```bash
docker logs -f zpush
```

This configuration provides a clean, safe, and maintainable way to route ActiveSync traffic to Z-Push while preserving Zimbra's advanced proxy features.