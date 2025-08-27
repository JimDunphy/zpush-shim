# Z-Push Zimbra Backend Installation Guide

**Release 74 - System Administrator Installation Guide**

This guide provides step-by-step instructions for system administrators to deploy the Z-Push Zimbra Backend with their Zimbra installation.

## Table of Contents
1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Installation Steps](#installation-steps)
4. [Configuration](#configuration)
5. [Verification](#verification)
6. [Troubleshooting](#troubleshooting)
7. [Maintenance](#maintenance)
8. [Uninstallation](#uninstallation)

## Overview

The Z-Push Zimbra Backend enables ActiveSync synchronization between mobile devices and Zimbra Collaboration Suite. This allows users to synchronize email, contacts, calendars, and tasks using the native email clients on their mobile devices.

### What You Get
- **Email Sync**: Two-way email synchronization with push notifications
- **Contact Sync**: Address book synchronization
- **Calendar Sync**: Calendar events and appointments
- **Task Sync**: Todo items and task management
- **Cross-Platform**: Works with iOS, Android, Windows Mobile, and Outlook

### Requirements
- Existing Z-Push 2.7+ installation
- Zimbra Collaboration Suite (OSE or Network Edition)
- PHP 7.4+ (PHP 8.1+ recommended)
- Apache or Nginx web server
- Composer (for dependencies)

## Prerequisites and Deployment Architecture

### Deployment Options: Same Machine vs Separate Machine

#### Option 1: Z-Push on Same Machine as Zimbra (Recommended for Small-Medium Deployments)
**Advantages:**
- No network latency between Z-Push and Zimbra
- Simplified SSL certificate management
- Lower resource requirements
- Easier troubleshooting

**Disadvantages:**
- Resource competition with Zimbra
- Single point of failure
- Potential port conflicts

**Best for:** <1,000 users, <500 folders per user

#### Option 2: Z-Push on Separate Machine (Recommended for Large Deployments)
**Advantages:**
- Dedicated resources for Z-Push
- Independent scaling
- Isolation from Zimbra issues
- Better security separation

**Disadvantages:**
- Network latency overhead
- More complex SSL/certificate setup
- Additional server maintenance

**Best for:** >1,000 users, >500 folders per user, high availability requirements

### 1. Z-Push Installation
Ensure Z-Push 2.7 or later is installed and functional:
```bash
# Verify Z-Push installation
ls /usr/share/z-push/
# Should show z-push directory structure
```

### 2. Zimbra Server Access
- Zimbra server accessible via HTTP/HTTPS
- Valid Zimbra user accounts for testing
- Network connectivity between Z-Push server and Zimbra server (if separate machines)

### 3. System Requirements
- PHP 7.4+ with cURL, mbstring, and soap extensions
- Composer package manager
- Write permissions to Z-Push directories
- **For separate machine**: Fast network connection to Zimbra (1Gbps+ recommended)

## Installation Steps

### Recommended Installation Method

**For optimal performance and ease of management, we recommend:**

1. **Same machine as Zimbra** (for most deployments)
2. **Integration with Zimbra's nginx** (leverages existing infrastructure)
3. **Dedicated PHP-FPM pool** (process isolation and optimization)
4. **Automated installation script** (reduces configuration errors)

### Quick Installation with Script

**Use the provided installation script for fastest setup:**

```bash
# Make script executable
chmod +x install-zimbra-backend.sh

# Automated installation
sudo ./install-zimbra-backend.sh --install

# Interactive configuration (sets up Zimbra URL, SSL settings, etc.)
sudo ./install-zimbra-backend.sh --configure

# Verify installation
./install-zimbra-backend.sh --verify
```

**The script automatically:**
- Installs backend files and dependencies
- Configures Z-Push to use Zimbra backend
- Sets optimal file permissions
- Creates basic configuration
- Provides verification tools

### Manual Installation (Advanced Users)

For custom deployments or learning purposes:

### Step 1: Download and Extract Backend
```bash
# Navigate to Z-Push backend directory
cd /usr/share/z-push/src/lib/backend/

# Create zimbra backend directory (if not exists)
sudo mkdir -p zimbra
cd zimbra

# Copy backend files to this directory
# (Replace with your actual file locations)
sudo cp /path/to/zimbra74/*.php .
sudo cp /path/to/zimbra74/INSTALL .
sudo cp /path/to/zimbra74/"Release Notes.txt" .
```

### Step 2: Install Dependencies
The backend requires the `halaxa/json-machine` composer package for improved performance:

```bash
# Navigate to zimbra backend directory
cd /usr/share/z-push/src/lib/backend/zimbra

# Install dependencies
sudo composer require halaxa/json-machine

# When prompted "No composer.json in current directory, do you want to use the one at /usr/share/z-push/src? [Y,n]?"
# Answer: N (No)
# This creates a separate composer.json for the zimbra backend
```

### Step 3: Set File Permissions
```bash
# Set appropriate ownership and permissions
sudo chown -R www-data:www-data /usr/share/z-push/src/lib/backend/zimbra/
sudo chmod -R 644 /usr/share/z-push/src/lib/backend/zimbra/*.php
sudo chmod 755 /usr/share/z-push/src/lib/backend/zimbra/
```

### Step 4: Configure Z-Push Core
Edit the main Z-Push configuration file:
```bash
sudo nano /usr/share/z-push/src/config.php
```

Add or modify these lines:
```php
// Set Zimbra as the backend provider
$BACKEND_PROVIDER = "BackendZimbra";
```

## Configuration

### Step 1: Basic Backend Configuration
Create or edit the Zimbra backend configuration:
```bash
sudo nano /usr/share/z-push/src/lib/backend/zimbra/config.php
```

**Minimum Required Configuration:**
```php
<?php
// Zimbra server URL (no trailing slash)
define('ZIMBRA_URL', 'https://mail.yourdomain.com');

// SSL certificate verification (set to false for self-signed certs)
define('ZIMBRA_SSL_VERIFYPEER', false);
define('ZIMBRA_SSL_VERIFYHOST', false);

// Connection retry settings for server maintenance
define('ZIMBRA_RETRIES_ON_HOST_CONNECT_ERROR', 5);
?>
```

### Step 2: Advanced Configuration (Optional)

**For environments with multiple calendar/contact folders:**
```php
// Enable virtual folders (recommended for most setups)
define('ZIMBRA_VIRTUAL_CONTACTS', true);
define('ZIMBRA_VIRTUAL_APPOINTMENTS', true);
define('ZIMBRA_VIRTUAL_TASKS', true);
define('ZIMBRA_VIRTUAL_NOTES', true);
```

**For better performance (Release 74 feature):**
```php
// Use REST API for improved sync performance
define('ZIMBRA_GETMESSAGELIST_USE_REST_API', true);
```

**For HTML email support:**
```php
// Enable HTML email for devices that support it
define('ZIMBRA_HTML', true);
```

### Step 3: Web Server Configuration

#### Performance-Optimized Nginx Configuration (Recommended)

**Why Nginx + PHP-FPM is Optimal for Z-Push:**
- **Better concurrency**: Handles multiple ActiveSync connections efficiently  
- **Lower memory usage**: Compared to Apache with mod_php
- **Process isolation**: PHP-FPM pools prevent one user's issues affecting others
- **Zimbra integration**: Can integrate with existing Zimbra nginx proxy

#### Option A: Nginx on Same Machine as Zimbra

**Integrate with Zimbra's existing nginx** (Recommended approach):

```bash
# Create Z-Push configuration for Zimbra's nginx
sudo nano /opt/zimbra/conf/nginx/includes/nginx.conf.web.z-push.default
```

```nginx
# Z-Push ActiveSync Configuration
# Add this to Zimbra's nginx configuration

# Optimize for ActiveSync long-polling
proxy_read_timeout 300s;
proxy_send_timeout 300s;
client_body_timeout 300s;
client_header_timeout 300s;

# Z-Push ActiveSync endpoint
location /Microsoft-Server-ActiveSync {
    # Rewrite to Z-Push
    rewrite ^/Microsoft-Server-ActiveSync(.*)$ /z-push/index.php$1 last;
}

location /z-push {
    alias /usr/share/z-push/src;
    index index.php;
    
    # Security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header X-XSS-Protection "1; mode=block";
    
    # ActiveSync specific optimizations
    client_max_body_size 50M;  # Large attachment support
    client_body_buffer_size 1M;
    
    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $request_filename;
        fastcgi_param PHP_VALUE "max_execution_time=300
                                 memory_limit=256M
                                 post_max_size=50M
                                 upload_max_filesize=50M";
        fastcgi_read_timeout 300s;
        fastcgi_send_timeout 300s;
        include fastcgi_params;
    }
    
    # Block access to sensitive files
    location ~ /\. {
        deny all;
    }
    
    location ~ \.(log|xml|conf)$ {
        deny all;
    }
}
```

**Activate the configuration:**
```bash
# Link the configuration
sudo ln -s /opt/zimbra/conf/nginx/includes/nginx.conf.web.z-push.default \
           /opt/zimbra/conf/nginx/includes/nginx.conf.web.z-push

# Restart Zimbra nginx
su - zimbra -c "zmnginxctl restart"
```

#### Option B: Standalone Nginx Configuration

**For separate machine or standalone nginx:**

```bash
# Create optimized nginx configuration
sudo nano /etc/nginx/sites-available/z-push
```

```nginx
server {
    listen 443 ssl http2;
    server_name mail.yourdomain.com;
    
    # SSL Configuration
    ssl_certificate /path/to/your/certificate.crt;
    ssl_certificate_key /path/to/your/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384;
    
    # ActiveSync optimizations
    client_max_body_size 50M;
    client_body_buffer_size 1M;
    client_body_timeout 300s;
    client_header_timeout 300s;
    send_timeout 300s;
    
    # Zimbra proxy pass (if Z-Push on separate machine)
    location / {
        proxy_pass https://zimbra.internal.domain;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # ActiveSync endpoint
    location /Microsoft-Server-ActiveSync {
        rewrite ^/Microsoft-Server-ActiveSync(.*)$ /z-push/index.php$1 last;
    }
    
    # Z-Push application
    location /z-push {
        alias /usr/share/z-push/src;
        index index.php;
        
        # Security headers
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options DENY;
        add_header X-XSS-Protection "1; mode=block";
        
        location ~ \.php$ {
            fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
            fastcgi_param SCRIPT_FILENAME $request_filename;
            fastcgi_param PHP_VALUE "max_execution_time=300
                                     memory_limit=256M
                                     post_max_size=50M
                                     upload_max_filesize=50M";
            fastcgi_read_timeout 300s;
            fastcgi_send_timeout 300s;
            fastcgi_buffer_size 32k;
            fastcgi_buffers 16 16k;
            include fastcgi_params;
        }
        
        # Block sensitive files
        location ~ /\.(log|xml|conf) {
            deny all;
        }
    }
}
```

#### PHP-FPM Optimization

**Create dedicated PHP-FPM pool for Z-Push:**

```bash
sudo nano /etc/php/8.1/fpm/pool.d/z-push.conf
```

```ini
[z-push]
user = www-data
group = www-data

# Socket configuration
listen = /var/run/php/php8.1-fpm-z-push.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

# Process management
pm = dynamic
pm.max_children = 50          # Adjust based on concurrent ActiveSync connections
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 15
pm.max_requests = 500

# ActiveSync optimizations
request_terminate_timeout = 300s  # Long-polling support
request_slowlog_timeout = 60s
slowlog = /var/log/php/z-push-slow.log

# PHP settings for ActiveSync
php_admin_value[max_execution_time] = 300
php_admin_value[memory_limit] = 256M
php_admin_value[post_max_size] = 50M
php_admin_value[upload_max_filesize] = 50M
php_admin_value[max_input_time] = 300
php_admin_value[default_socket_timeout] = 300

# Error logging
php_admin_value[log_errors] = On
php_admin_value[error_log] = /var/log/php/z-push-error.log
```

**Update nginx to use dedicated pool:**
```nginx
location ~ \.php$ {
    fastcgi_pass unix:/var/run/php/php8.1-fpm-z-push.sock;  # Dedicated pool
    # ... rest of configuration
}
```

**Restart services:**
```bash
sudo systemctl restart php8.1-fpm
sudo systemctl restart nginx
```

#### Apache Configuration (Alternative)

**If you must use Apache:**

```apache
<VirtualHost *:443>
    ServerName mail.yourdomain.com
    DocumentRoot /var/www/html
    
    # SSL Configuration
    SSLEngine on
    SSLCertificateFile /path/to/certificate.crt
    SSLCertificateKeyFile /path/to/private.key
    
    # ActiveSync endpoint
    Alias /Microsoft-Server-ActiveSync /usr/share/z-push/src/index.php
    Alias /z-push /usr/share/z-push/src
    
    <Directory "/usr/share/z-push/src">
        Options -Indexes
        AllowOverride None
        Require all granted
        
        # PHP optimizations for ActiveSync
        php_admin_value max_execution_time 300
        php_admin_value memory_limit 256M
        php_admin_value post_max_size 50M
        php_admin_value upload_max_filesize 50M
        php_admin_value default_socket_timeout 300
        
        # Error logging
        php_flag log_errors on
        php_value error_log /var/log/z-push/error.log
    </Directory>
    
    # Security headers
    Header always set X-Content-Type-Options nosniff
    Header always set X-Frame-Options DENY
    Header always set X-XSS-Protection "1; mode=block"
</VirtualHost>
```

#### Performance Comparison

| Configuration | Concurrent Users | Memory Usage | CPU Efficiency |
|---------------|------------------|--------------|----------------|
| **Nginx + PHP-FPM** | 500+ | Low | High |
| **Apache + mod_php** | 200-300 | High | Medium |
| **Zimbra nginx integration** | 1000+ | Lowest | Highest |

### Step 4: Zimbra Server Configuration

**Important: Whitelist Z-Push Server IP**
If Z-Push runs on a different server than Zimbra (version 8.0+), whitelist the Z-Push server IP:

```bash
# On Zimbra server, add Z-Push IP to DoS filter whitelist
su - zimbra
zmprov md yourdomain.com zimbraHttpThrottleSafeIPs "192.168.1.100"
# Replace 192.168.1.100 with your Z-Push server IP

# Restart Zimbra services
zmcontrol restart
```

## Verification

### Step 1: Test Backend Loading
```bash
# Test if backend loads without errors
php -f /usr/share/z-push/src/z-push-admin.php -a list
```

Expected output should include backend information without errors.

### Step 2: Test Zimbra Connectivity
```bash
# Test direct connectivity to Zimbra
curl -k https://mail.yourdomain.com/service/soap
```

Should return Zimbra SOAP service response.

### Step 3: Test ActiveSync Endpoint
```bash
# Test Z-Push ActiveSync endpoint
curl -k https://yourserver.com/z-push/
```

Should return Z-Push version information.

### Step 4: Mobile Device Test
1. **Add Account on Mobile Device:**
   - Account Type: Exchange/ActiveSync
   - Server: `yourserver.com/z-push`
   - Username: Zimbra username
   - Password: Zimbra password

2. **Verify Sync:**
   - Check email synchronization
   - Verify contacts appear
   - Test calendar sync
   - Send a test email

### Step 5: Log File Verification
Check Z-Push logs for successful authentication and sync:
```bash
# View Z-Push logs
tail -f /var/log/z-push/z-push.log

# Look for successful login entries like:
# [INFO] User 'testuser' authenticated successfully
# [INFO] BackendZimbra->Logon(): Success
```

## Troubleshooting

### Common Issues and Solutions

#### 1. Authentication Failures
**Problem:** Mobile devices cannot authenticate

**Solutions:**
```bash
# Check Zimbra URL configuration
grep ZIMBRA_URL /usr/share/z-push/src/lib/backend/zimbra/config.php

# Test direct Zimbra authentication
curl -k -d "loginOp=login&username=testuser&password=testpass" \
https://mail.yourdomain.com/service/preauth

# Verify SSL settings if using HTTPS
```

#### 2. SSL Certificate Issues
**Problem:** SSL verification errors

**Solution:**
```php
// In config.php, disable SSL verification for self-signed certificates
define('ZIMBRA_SSL_VERIFYPEER', false);
define('ZIMBRA_SSL_VERIFYHOST', false);
```

#### 3. Sync Performance Issues
**Problem:** Slow synchronization

**Solutions:**
```php
// Enable REST API (Release 74+)
define('ZIMBRA_GETMESSAGELIST_USE_REST_API', true);

// Limit sync window
define('ZIMBRA_SYNC_WINDOW_DAYS', 90);
```

#### 4. Missing Dependencies
**Problem:** "Class 'JsonMachine\\Items' not found"

**Solution:**
```bash
cd /usr/share/z-push/src/lib/backend/zimbra
sudo composer require halaxa/json-machine
sudo chown -R www-data:www-data vendor/
```

### Debug Mode
Enable detailed logging for troubleshooting:
```php
// In Z-Push main config.php
define('LOGLEVEL', LOGLEVEL_DEBUG);
define('LOGFILE', '/var/log/z-push/debug.log');
```

### Log Locations
- **Z-Push Logs:** `/var/log/z-push/`
- **Apache Logs:** `/var/log/apache2/error.log`
- **Zimbra Logs:** `/opt/zimbra/log/mailbox.log`

## Maintenance

### Regular Tasks
1. **Monitor Log Files:**
```bash
# Weekly log review
logrotate -f /etc/logrotate.d/z-push
tail -100 /var/log/z-push/z-push.log | grep ERROR
```

2. **Update Dependencies:**
```bash
# Monthly dependency updates
cd /usr/share/z-push/src/lib/backend/zimbra
sudo composer update
```

3. **Clean State Files:**
```bash
# Clean orphaned sync states (be careful!)
find /var/lib/z-push/state -name "*" -mtime +30 -type f
# Review before deleting
```

### Backup Recommendations
```bash
# Backup Z-Push configuration
tar -czf z-push-backup-$(date +%Y%m%d).tar.gz \
    /usr/share/z-push/src/config.php \
    /usr/share/z-push/src/lib/backend/zimbra/ \
    /var/lib/z-push/state/
```

### Updates
When updating the Zimbra backend:
1. Backup current installation
2. Stop web server
3. Replace PHP files
4. Update dependencies if needed
5. Review configuration for new options
6. Start web server
7. Test functionality

## Uninstallation

### Step 1: Stop Synchronization
1. Remove ActiveSync accounts from all mobile devices
2. Allow final sync to complete

### Step 2: Remove Backend Files
```bash
# Remove Zimbra backend
sudo rm -rf /usr/share/z-push/src/lib/backend/zimbra/

# Revert Z-Push to default backend
sudo nano /usr/share/z-push/src/config.php
# Change: $BACKEND_PROVIDER = "BackendIMAP"; (or your preferred backend)
```

### Step 3: Clean State Files
```bash
# Remove sync state data (optional)
sudo rm -rf /var/lib/z-push/state/
```

### Step 4: Remove Logs
```bash
# Clean up logs
sudo rm -f /var/log/z-push/zimbra-*.log
```

## Support and Resources

- **Project Page:** https://sourceforge.net/projects/zimbrabackend/
- **Support Tickets:** https://sourceforge.net/p/zimbrabackend/support-requests/
- **Z-Push Documentation:** https://z-push.org/
- **Zimbra Documentation:** https://wiki.zimbra.com/

## Success Indicators

Your installation is successful when:
- ✅ Mobile devices can add Exchange accounts using Z-Push server
- ✅ Emails sync bidirectionally without errors
- ✅ Contacts and calendar entries appear on devices
- ✅ Push notifications work for new emails
- ✅ Log files show successful authentication and sync operations
- ✅ Multiple devices can sync simultaneously without conflicts

## Performance Optimization and Best Practices

### Deployment Architecture Best Practices

#### Same Machine vs Separate Machine Performance Analysis

**Same Machine Deployment (Recommended for most scenarios):**
```bash
# Performance benefits:
# - Zero network latency between Z-Push and Zimbra
# - Shared memory/cache benefits  
# - Single SSL certificate management
# - Zimbra nginx integration (optimal)

# Resource considerations:
# - PHP-FPM pool: 256MB + (users × 2MB)  
# - Additional CPU: ~10-15% overhead
# - Network: No additional bandwidth
```

**Separate Machine Deployment:**
```bash
# When to choose:
# - >1,000 concurrent ActiveSync users
# - High availability requirements
# - Security isolation needs
# - Dedicated Z-Push server resources

# Performance considerations:
# - Network latency: +5-15ms per request
# - Bandwidth: ~1Mbps per 100 concurrent users
# - Additional SSL handshakes
```

### Nginx Integration Performance Benefits

**Why integrate with Zimbra's nginx:**

1. **Shared connection pooling**: Zimbra's nginx already has optimized connections
2. **Unified SSL termination**: Single certificate, optimized SSL handling
3. **Resource efficiency**: No duplicate processes
4. **Zimbra proxy benefits**: Leverages existing load balancing and failover

**Performance comparison:**

| Deployment Method | Memory Usage | CPU Overhead | Concurrent Users |
|-------------------|--------------|--------------|------------------|
| Zimbra nginx + PHP-FPM | 50MB base + 2MB/user | 5-10% | 1000+ |
| Standalone nginx + PHP-FPM | 100MB base + 3MB/user | 10-15% | 500+ |
| Apache + mod_php | 200MB base + 8MB/user | 20-30% | 200+ |

### PHP-FPM Pool Optimization

**Calculate optimal pool size:**
```bash
# Formula: max_children = (Available RAM) / (Average PHP memory per process)
# ActiveSync processes: ~8-12MB each
# Safe calculation: max_children = (Available RAM × 0.8) / 12MB

# Example for 4GB RAM server:
# max_children = (4096MB × 0.8) / 12MB = 273
# Round down to: max_children = 250

# For shared Zimbra server (recommend 1GB for Z-Push):
# max_children = (1024MB × 0.8) / 12MB = 68
# Set to: max_children = 60
```

### Monitoring and Maintenance

#### Performance Monitoring Commands

```bash
# Monitor PHP-FPM pool status
curl http://localhost/fpm-status

# Check ActiveSync connection count
ss -tn | grep :443 | wc -l

# Monitor Z-Push memory usage
ps aux | grep php-fpm | awk '{sum+=$6} END {print sum/1024 " MB"}'

# Check nginx ActiveSync requests
tail -f /var/log/nginx/access.log | grep "Microsoft-Server-ActiveSync"

# Monitor Zimbra SOAP requests from Z-Push
su - zimbra -c "tail -f /opt/zimbra/log/mailbox.log | grep 'SOAP'"
```

#### Regular Maintenance Tasks

```bash
# Weekly: Clean old state files (older than 30 days)
find /var/lib/z-push/state -type f -mtime +30 -delete

# Monthly: Restart PHP-FPM to clear memory leaks
systemctl restart php8.1-fpm

# Monitor disk usage of state directory
du -sh /var/lib/z-push/state/

# Check for failed sync attempts
grep "FATAL" /var/log/z-push/z-push.log | tail -20
```

### Troubleshooting Performance Issues

#### High Memory Usage
```bash
# Check for memory leaks in PHP-FPM
cat /proc/$(pgrep php-fpm | head -1)/status | grep VmRSS

# If memory usage > 50MB per process:
# 1. Restart PHP-FPM: systemctl restart php8.1-fpm
# 2. Consider reducing max_requests in pool configuration
# 3. Monitor for specific users causing issues
```

#### Slow Sync Performance
```bash
# Enable Z-Push debug logging
echo "define('LOGLEVEL', LOGLEVEL_DEBUG);" >> /usr/share/z-push/src/config.php

# Check for slow Zimbra responses
grep "SOAP.*took" /var/log/z-push/z-push.log | tail -10

# Monitor long-running PHP processes
ps aux | grep php-fpm | awk '$10 > 60 {print}'
```

### Security Considerations

#### Zimbra Integration Security
```bash
# Ensure Z-Push uses Zimbra's security context
# Set proper file permissions
chown -R zimbra:zimbra /usr/share/z-push/src/lib/backend/zimbra/
chmod 640 /usr/share/z-push/src/lib/backend/zimbra/config.php

# Monitor authentication attempts
grep "authentication failed" /var/log/z-push/z-push.log
```

#### Network Security (Separate Machine)
```bash
# Restrict Z-Push server access to Zimbra
# On Zimbra server firewall:
ufw allow from Z_PUSH_SERVER_IP to any port 443
ufw allow from Z_PUSH_SERVER_IP to any port 7071

# Use private network if possible
# Configure Zimbra backend to use internal IP
define('ZIMBRA_URL', 'https://10.0.1.100');  # Internal IP
```

**Congratulations!** Your Z-Push Zimbra Backend installation is now complete and optimized for production use.