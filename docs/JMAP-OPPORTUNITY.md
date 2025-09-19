# JMAP Implementation Opportunity for Zimbra FOSS

**Date**: August 22, 2025  
**Context**: Research into extending Z-Push Java Shim to support JMAP protocol  
**Inspiration**: Stalwart's original JMAP proxy architecture (now archived)

## Executive Summary

The Z-Push Java Shim provides an excellent foundation for implementing JMAP support for Zimbra FOSS, addressing a critical gap in the ecosystem as new JMAP-native mobile clients emerge. Stalwart's archived proxy repositories provide a proven roadmap for this approach.

## The Opportunity

### Market Need
- **Modern mobile clients**: New JMAP-native email apps need Zimbra support
- **API modernization**: Zimbra FOSS lacks modern REST API access
- **Performance benefits**: Same 20-60x improvement over SOAP as Z-Push shim
- **Standards compliance**: JMAP is an open standard vs proprietary ActiveSync

### Timing Advantage
- **Stalwart evolution**: Moved from proxy model to all-in-one server, leaving proxy gap
- **Existing foundation**: Z-Push shim already solves the hard integration problems
- **FOSS community**: Strong demand for modern Zimbra capabilities

## Technical Foundation

### Current Z-Push Shim Capabilities
Already implemented and working:
- ✅ **Direct Zimbra API access** (accounts, folders, messages, search)
- ✅ **JSON handling** (Gson library)
- ✅ **Authentication with 2FA/app passwords** (EAS context)
- ✅ **Zimbra extension framework** (proper integration)
- ✅ **Cross-platform development** (dev machine + production)
- ✅ **Performance optimization** (20-60x faster than SOAP)

### JMAP Protocol Alignment
Core JMAP concepts map well to existing shim functionality:

| JMAP Concept | Current Shim Method | Status |
|--------------|-------------------|---------|
| Session endpoint | `handleAuth()` | ✅ Ready |
| Mailbox/get | `handleGetFolders()` | ✅ Ready |
| Email/get | `handleGetMessages()` | ✅ Ready |
| Email/get (individual) | `handleGetMessage()` | ✅ Ready |
| Account info | `handleGetUserInfo()` | ✅ Ready |

## Stalwart Reference Architecture

### Original Proxy Model (Now Archived)
**Repositories to study**:
- `stalwartlabs/jmap-server` (archived) - Core JMAP server implementation
- `stalwartlabs/imap-to-jmap` (archived) - IMAP4 to JMAP proxy

**Architecture Pattern**:
```
Legacy Mail System → IMAP → imap-to-jmap proxy → JMAP clients
Zimbra System     → Java Shim → JMAP endpoints → JMAP clients
```

### Key Stalwart Features to Emulate
- **Full JMAP compliance** (Core, Mail, WebSocket)
- **Protocol translation** (IMAP4 requests → JMAP requests)
- **High availability** support
- **Memory-safe implementation** (Rust/Java advantage)
- **OAuth 2.0** and modern authentication
- **Rate limiting** and security

## Implementation Strategy

### Phase 1: Core JMAP Support
Extend existing Z-Push shim with JMAP endpoints:
- **Session endpoint** (`/jmap/session`) - Authentication and capabilities
- **API endpoint** (`/jmap/api`) - Core JMAP method calls
- **Mailbox operations** - Folder listing and management
- **Email operations** - Message listing and retrieval

### Phase 2: Advanced Features
- **State management** - JMAP state tokens for efficient sync
- **Change detection** - Leverage Zimbra WaitSet API for real-time updates
- **Advanced queries** - JMAP's sophisticated filtering system
- **Batch operations** - Multiple method calls in single request

### Phase 3: Modern Capabilities
- **WebSocket support** - Real-time push notifications
- **EventSource** - Server-sent events for web clients
- **Full-text search** - Integrate with Zimbra's search capabilities
- **CalDAV/CardDAV bridge** - Leverage JMAP for calendars/contacts

## Technical Advantages

### Leveraging Existing Infrastructure
- **Extension framework**: Already integrated with Zimbra
- **Build system**: Cross-platform Ant-based development
- **Authentication**: EAS context handles 2FA/app passwords
- **Performance**: Direct API access bypasses SOAP overhead
- **Deployment**: Proven extension deployment model

### Cross-Platform Development Model
- **Development machines**: Mock JMAP responses for testing
- **Production deployment**: Real Zimbra API integration
- **Runtime detection**: Automatic environment adaptation

## Market Impact

### For Zimbra FOSS Community
- **Modern API access** without waiting for official Zimbra JMAP
- **Mobile client support** for new JMAP-native applications
- **Performance benefits** for web-based email clients
- **Standards compliance** enables broader ecosystem integration

### Competitive Advantage
- **First comprehensive JMAP** implementation for Zimbra
- **Open source solution** for FOSS community
- **Proven performance** foundation from Z-Push shim
- **Incremental development** - build on existing success

## Development Resources

### Study Materials
1. **Archived Stalwart repositories** - Protocol implementation patterns
2. **JMAP RFC specification** - Official protocol documentation
3. **Existing Z-Push shim code** - Architecture and Zimbra integration
4. **JMAP client implementations** - Test compatibility targets

### Technical References
- **JMAP Core RFC 8620** - Base protocol specification
- **JMAP Mail RFC 8621** - Email-specific extensions
- **Zimbra SOAP API docs** - Understanding backend capabilities
- **Modern email client analysis** - Understanding client expectations

## Next Steps (When Time Permits)

1. **Archive repository analysis** - Study Stalwart's JMAP implementation patterns
2. **Protocol mapping** - Detailed mapping of JMAP methods to Zimbra APIs
3. **Proof of concept** - Basic JMAP Session and Mailbox/get endpoints
4. **Mobile client testing** - Identify target JMAP applications for compatibility
5. **Community engagement** - Gauge FOSS Zimbra community interest

## Strategic Notes

### Why This Matters Now
- **Mobile email evolution**: Traditional IMAP clients being replaced by JMAP natives
- **API modernization trend**: Organizations moving away from proprietary protocols
- **Zimbra FOSS gap**: No modern API access without commercial features
- **Proven foundation**: Z-Push shim demonstrates viability and performance

### Risk Mitigation
- **Incremental approach**: Build on proven Z-Push shim foundation
- **Fallback compatibility**: Maintain existing ActiveSync functionality
- **Open source model**: Community can contribute and maintain
- **Standards-based**: JMAP is vendor-neutral protocol

---

**Key Insight**: The Z-Push Java Shim already solves the hardest problems (Zimbra integration, performance, authentication). Adding JMAP is primarily about protocol translation - exactly what Stalwart's archived proxy proved was viable.

**Market Opportunity**: Zimbra FOSS community gets modern email API access, enabling next-generation client applications without waiting for official vendor support.