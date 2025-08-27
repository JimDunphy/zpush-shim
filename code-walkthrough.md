# Z-Push Java Shim: Code Walkthrough

This document provides a technical walkthrough of the `ZPushShimCompat.java` code for developers, particularly those with a background in C, to understand its architecture, security model, and data flow.

## 1. How It Works: The Big Picture

The Java shim acts as a high-performance bridge between the Z-Push PHP backend and the Zimbra server's internal APIs. Think of this Java code not as a standalone program, but as a **shared library (`.so` or `.dll`)** that is loaded by the Zimbra web server (specifically, the Jetty servlet container). The Z-Push PHP backend makes HTTP requests to this "library" to perform actions.

### Entry Point & Request Routing

The main entry point for all requests from the PHP backend is the `doPost` method. This is conceptually similar to a `main()` function in a C-based CGI script.

```java
public void doPost(HttpServletRequest request, HttpServletResponse response)
```

This method is called by the web server when a `POST` request hits the shim's URL. Its primary job is to act as a dispatcher. It reads an `action` parameter from the request and uses a `switch` statement to route the request to the appropriate handler function (e.g., `handleAuth`, `handleGetFolders`).

```java
String action = request.getParameter("action");
// ...
switch (action.toLowerCase()) {
    case "authenticate":
        handleAuth(request, response);
        break;
    case "getfolders":
        handleGetFolders(request, response);
        break;
    // ... etc.
}
```
This is analogous to parsing `argv[1]` in a C program to determine which command to execute.

## 2. Authentication: How It's Secured

The shim's security model is based on bearer tokens. A client must first authenticate to get a temporary token and then present that token on all subsequent requests.

1.  **The Authentication Endpoint (`handleAuth`):** This is the front door. It's the only action that accepts a username and password. In a real deployment, it calls the core Zimbra authentication API to verify credentials and generate a session token (`authToken`).

2.  **Token Validation:** Every other method that performs an action (`handleGetFolders`, `handleGetMessages`, etc.) begins with a critical security check:

    ```java
    private void handleGetFolders(HttpServletRequest request, HttpServletResponse response) {
        String authToken = request.getParameter("authToken");
        
        if (authToken == null) {
            writeError(response, "Missing authToken", 401); // 401 is "Unauthorized"
            return;
        }
        // ... proceed only if token exists ...
    }
    ```
    If the `authToken` is missing, the method immediately stops and returns an HTTP `401 Unauthorized` error. This ensures that no data-related actions can be performed without a valid session token.

## 3. Data Handling and Sanitization

This is a key area where Java development practices diverge from typical C development.

*   **Input:** The code uses `request.getParameter("param_name")` to retrieve all input strings from the HTTP request.

*   **Sanitization:** There is **no explicit data sanitization code** (e.g., escaping special characters). This is a deliberate design choice.

    **Why?** The shim is designed to pass input directly to Zimbra's internal Java APIs. Unlike building a raw SQL query string in C (e.g., `sprintf(query, "SELECT * FROM users WHERE name = '%s'", user_input)`), which is highly vulnerable to SQL injection, calling a pre-compiled Java method like `mailbox.getFolderByName(folderName)` is generally safe. The responsibility for handling the input securely lies with the underlying Zimbra API itself.

    This model relies on the **trust assumption** that Zimbra's internal APIs are robust and secure against injection attacks. The shim acts as a pass-through mechanism, not a security filter.

## 4. Cross-Platform Architecture for Testing

A key feature for developers and testing is the shim's ability to run in two modes: "development" and "zimbra".

The `isZimbraAvailable()` method makes this possible:
```java
private boolean isZimbraAvailable() {
    try {
        // Tries to find a core Zimbra class at runtime
        Class.forName("com.zimbra.cs.account.Provisioning");
        return true;
    } catch (ClassNotFoundException e) {
        // Fails on a dev machine where Zimbra isn't installed
        return false;
    }
}
```

Every handler method uses this check to alter its behavior:
*   **In a test harness/dev environment:** `isZimbraAvailable()` returns `false`. The methods then return hardcoded, predictable "mock" data. This is perfect for testing the PHP frontend or other clients without needing a live Zimbra server.
*   **On a production Zimbra server:** `isZimbraAvailable()` returns `true`, and the code proceeds to call the (currently stubbed out) logic for interacting with the real Zimbra APIs.

This dual-mode design is a powerful feature for building a robust test harness.

## 5. Project Structure: Why Three Java Files?

The project uses a three-file structure to separate concerns, making the code both production-ready and easy to test. Each file has a distinct role:

### `ZPushShimExtension.java` (The Entry Point / Wrapper)

This is the **official entry point** that the Zimbra server loads. When a request from the PHP backend arrives at the shim's URL (`/service/extension/zpush-shim`), this class's `doPost` method is the first to be called.

Its primary job is to be a thin wrapper. It creates an instance of the actual implementation (like `ZPushShimCompat`) and delegates the request to it. This separates the Zimbra-specific extension machinery (`init`, `destroy`) from the core application logic.

### `ZPushShim.java` (The Production Code)

This is the **real, production-level implementation**.

*   **Direct Zimbra Dependencies:** It directly imports and uses Zimbra server libraries (`com.zimbra.cs.account.*`, `com.zimbra.cs.mailbox.*`, etc.). This code will *only* compile and run on a machine with the Zimbra server software installed.
*   **High-Performance Logic:** The methods in this class contain the actual logic that calls Zimbra's internal APIs to perform tasks like authentication (`prov.authAccount(...)`) and folder listing (`mbox.getFolderList(...)`).

### `ZPushShimCompat.java` (The Development/Test Code)

This is the **development-friendly, compatible version**.

*   **No Zimbra Dependencies:** It is designed to be compiled and run anywhere, especially on a developer's machine without a local Zimbra installation.
*   **Provides Mock Data:** Its methods return fake, hardcoded data, which is perfect for a test harness. It allows developers to test the entire request/response flow and the PHP client without needing a live Zimbra backend.

### How They Fit Together

The build system (`build.xml`) is responsible for choosing which implementation to package into the final `.jar` file:

*   A **`development` build** would package `ZPushShimExtension.java` and `ZPushShimCompat.java`.
*   A **`production` build** would package `ZPushShimExtension.java` and `ZPushShim.java`.

This powerful pattern allows for easy local development and testing while ensuring maximum performance in production.

## 6. A Deep Dive into the Authentication Flow

To understand the real logic, we will trace the `handleAuth` method in the production file, `ZPushShim.java`. This flow introduces several core Java concepts.

```java
// In ZPushShim.java
private void handleAuth(HttpServletRequest request, HttpServletResponse response)
        throws ServiceException, IOException {
```
The `throws` clause is part of Java's "checked exception" system. It declares that this function might fail in specific ways, forcing the calling function (`doPost`) to handle those potential failures within a `try...catch` block.

### Step 1: Get User Credentials and Account Object

```java
    String username = request.getParameter("username");
    String password = request.getParameter("password");

    Account account = prov.getAccount(AccountBy.name, username);
    if (account == null) {
        writeError(response, "Account not found", 401);
        return;
    }
```
First, the code retrieves the username and password strings from the request. Then, it makes its first call to a Zimbra API: `prov.getAccount(...)`. `prov` is an instance of Zimbra's `Provisioning` class. This call fetches the user's account object from Zimbra. If the user doesn't exist, it returns `null` (similar to a `NULL` pointer in C), and an error is returned.

### Step 2: Build the Authentication Context with a `Map`

```java
    Map<String, Object> authContext = new HashMap<>();
    authContext.put(AuthContext.AC_PROTOCOL, "eas");
    authContext.put(AuthContext.AC_USER_AGENT, "Z-Push-Shim/1.0");
    authContext.put(AuthContext.AC_REMOTE_IP, request.getRemoteAddr());
```
This section introduces the `Map`, a fundamental Java data structure.

*   **Concept:** A `Map` is an "associative array" or "hash table" for storing key-value pairs. In C, you might implement this with a `struct` and a linked list, but `Map` provides a standardized, high-performance implementation.
*   **Declaration:** `Map<String, Object> authContext` declares a variable `authContext`.
    *   `Map` is the interface (the abstract concept).
    *   `HashMap` is the concrete implementation we are creating.
    *   `<String, Object>` defines the types: keys are `String`s, and values are of type `Object`. `Object` is the base for all objects in Java, making it similar to a `void*` that can hold a reference to anything.
*   **Usage:** `authContext.put(key, value)` adds an item. Here, we build a context to tell the Zimbra API *how* the user is logging in. Specifying the protocol as `eas` (Exchange ActiveSync) is critical for enabling 2FA and app-specific passwords.

### Step 3: The `try...catch` Block and the API Call

```java
    try {
        AuthToken authToken = prov.authAccount(account, password, AuthContext.Protocol.soap, authContext);
        
        // ... success logic ...

    } catch (AuthFailedServiceException e) {
        // ... failure logic ...
    }
```
This is Java's primary error handling mechanism.

*   **The `try` Block:** The code attempts to execute the logic inside this block. The main call is `prov.authAccount(...)`, which asks Zimbra to verify the user's password against the provided context. If it succeeds, it returns an `AuthToken` object containing the session key, and the rest of the `try` block continues.
*   **The `catch` Block:** If `prov.authAccount` fails, it "throws" an `AuthFailedServiceException`. Execution of the `try` block stops immediately, and the `catch` block is executed. This is different from checking return codes in C. The failure path is handled in an entirely separate block of code. The `e` variable is an object containing rich information about the error.

### Step 4: Handle Success or Failure

*   **On Success:**
    ```java
    // Add the new token to an in-memory cache for performance
    tokenCache.put(authToken.getEncoded(), authToken);

    // Build a Map to structure the JSON response
    Map<String, Object> result = new HashMap<>();
    result.put("success", true);
    result.put("authToken", authToken.getEncoded());
    // ...
    
    // Send the successful JSON response back to the PHP client
    writeJson(response, result);
    ```

*   **On Failure:**
    ```java
    // The catch block is executed
    ZimbraLog.misc.info("Z-Push Shim: authentication failed...");
    writeError(response, "Authentication failed", 401);
    ```
    A failure is logged, and a JSON error message with HTTP status `401 Unauthorized` is sent back to the PHP client.

## 7. Java Concepts: The Diamond Operator (`<>`)

An astute observer might notice a difference in how generic objects like `HashMap` are created in this codebase compared to older Java code.

**The Modern Syntax (Java 7+):**
```java
Map<String, Object> myMap = new HashMap<>();
```

**The Older Syntax (Before Java 7):**
```java
Map<String, Object> myMap = new HashMap<String, Object>();
```

You are correct that the type declarations (`String, Object`) are "missing" inside the angle brackets on the right-hand side in the modern syntax. This is not an error; it's a language feature introduced in Java 7 called the **diamond operator**.

### What is Type Inference?

The diamond operator (`<>`) tells the Java compiler to **infer** (or deduce) the generic types from the variable declaration on the left-hand side.

When the compiler sees `Map<String, Object> myMap = new HashMap<>();`, it looks at the declaration `Map<String, Object>`, understands that the required types are `String` and `Object`, and automatically applies them to the `HashMap` being created.

This was introduced to reduce verbosity and boilerplate code, as repeating the types on both sides was considered redundant. Both forms are functionally identical, but the version with the diamond operator is the modern, preferred standard. It's purely a piece of "syntactic sugar" to make the programmer's life easier.

## 8. End-to-End Trace: Getting a Folder List

Let's trace the `handleGetFolders` method in `ZPushShim.java` to see how the `authToken` is used and how a list of data is prepared, serialized with `writeJson`, and consumed by the client.

### Step 1: Authorization and User Scoping

```java
private void handleGetFolders(HttpServletRequest request, HttpServletResponse response)
        throws ServiceException, IOException {

    // 1. Get the token string from the request
    String authTokenStr = request.getParameter("authToken");
    if (authTokenStr == null) { /* ... error ... */ }

    // 2. Validate the token and get the token object
    AuthToken authToken = getValidatedAuthToken(authTokenStr);
    if (authToken == null) { /* ... error ... */ }

    // 3. Get the specific user account tied to this token
    Account account = authToken.getAccount();
    
    // 4. Get the mailbox for ONLY that user
    Mailbox mbox = MailboxManager.getInstance().getMailboxByAccount(account);
```
This is the security model in action. The request is only authorized if it presents a valid, non-expired token. Crucially, all subsequent operations are performed using the `account` and `mbox` objects derived *from the token itself*. This makes it impossible for this request to access data from any other user's mailbox.

### Step 2: Retrieving and Preparing the Data

```java
    // Call the internal Zimbra API to get a List of complex Folder objects
    List<Folder> allFolders = mbox.getFolderList(octxt, MailItem.Type.UNKNOWN);

    // Create a new, empty List that will hold our simplified folder data
    List<Map<String, Object>> folderList = new ArrayList<>();

    // Loop through each complex Folder object
    for (Folder folder : allFolders) {
        // Create a simple Map for the JSON response
        Map<String, Object> folderData = new HashMap<>();
        
        // Copy only the data we need into the simple Map
        folderData.put("id", folder.getId());
        folderData.put("name", folder.getName());
        // ... etc.
        
        // Add the simple Map to our response list
        folderList.add(folderData);
    }
```
This section introduces two more core Java concepts:

*   **`List`**: A `List` is an ordered collection, like a dynamic array. `List<Folder>` is a type-safe list that can only hold `Folder` objects. `ArrayList` is a common and efficient implementation.
*   **Enhanced `for` loop**: The syntax `for (Folder folder : allFolders)` is a clean way to iterate over every item in a collection. It's the equivalent of a `foreach` loop in other languages and avoids manual index management (`for (int i=0; ...)`).

The logic here is to transform the list of complex, internal `Folder` objects into a `List` of simple `Map`s, which is an ideal structure for clean JSON serialization.

### Step 3: `writeJson` and the Client Response

The final step in the Java code is `writeJson(response, folderList);`.

```java
private void writeJson(HttpServletResponse response, Object data) throws IOException {
    // 1. Set the HTTP header to tell the client what's coming
    response.setContentType("application/json");

    // 2. Use the Gson library to serialize the Java List into a JSON string
    String jsonOutput = gson.toJson(data);

    // 3. Write the JSON string to the HTTP response body
    response.getWriter().write(jsonOutput);
}
```
The `gson.toJson()` call is the serialization engine. It converts the `List<Map<String, Object>>` into a clean JSON string like this:
```json
[
  {"id":2, "name":"Inbox", "path":"/Inbox"},
  {"id":5, "name":"Sent", "path":"/Sent"},
  {"id":257, "name":"Folder With Spaces", "path":"/Folder With Spaces"}
]
```

### Step 4: What the PHP Client Sees

The Z-Push PHP script that made the request now receives this HTTP response. To use this data, it simply needs to decode the JSON body:

```php
// In the PHP client (e.g., zimbra.php)
$json_response_from_shim = $this->callShim(...);

// Decode the JSON string into a native PHP associative array
$folders_array = json_decode($json_response_from_shim, true);

// The PHP code can now work with this simple array
foreach ($folders_array as $folder) {
    echo $folder['name']; // Prints "Inbox", "Sent", etc.
}
```
This completes the round trip. The `writeJson` method is the bridge that allows the complex Java objects in the shim to be consumed as simple associative arrays in the PHP client.

## 9. The Full Round Trip: From Login to Data

This section provides the complete, end-to-end trace of the entire process, showing how the `authToken` acts as the glue between the initial login and subsequent data requests.

### Part 1: The Login Request (PHP -> Java `handleAuth`)

It begins in the Z-Push PHP backend, which needs to authenticate the user.

**PHP Side (Conceptual):**
```php
$postData = [
    'action'   => 'authenticate',
    'username' => 'jad',
    'password' => 'my_password'
];
$json_response = $this->call_the_java_shim($postData);
```
This HTTP request is sent to the Java shim, where it's routed to the `handleAuth` method. The method verifies the credentials and prepares a success response.

**Java Side (`handleAuth`):**
```java
    // ... authentication succeeds ...
    AuthToken authToken = ... // A new token object is created
    
    Map<String, Object> result = new HashMap<>();
    result.put("success", true);
    result.put("authToken", authToken.getEncoded()); // Let's say this is "xyz123"
    result.put("accountId", "some-id-456");
    
    writeJson(response, result); // Send the response
```

### Part 2: `writeJson` (Detailed View)

The `writeJson` method is called to send the response back to the PHP client.

```java
private void writeJson(HttpServletResponse response, Object data) throws IOException {
    // 1. Set the MIME type to tell the client the content is JSON.
    response.setContentType("application/json");

    // 2. Set the character encoding to UTF-8. This is critical.
    // It modifies the header to "application/json; charset=UTF-8" and ensures
    // that any non-ASCII characters in the data (e.g., "Jad's Résumé")
    // are encoded correctly and not corrupted.
    response.setCharacterEncoding("UTF-8");

    // 3. Use the Gson library to serialize the Java Map into a JSON string.
    // The resulting string is: '{"success":true,"authToken":"xyz123",...}'
    String jsonOutput = gson.toJson(data);

    // 4. Write the final JSON string to the HTTP response body.
    response.getWriter().write(jsonOutput);
}
```

### Part 3: The PHP Client Receives the Token

The PHP script now receives the HTTP response from the shim.

**PHP Side:**
```php
// $json_response now holds the string: '{"success":true,"authToken":"xyz123",...}'
$response_array = json_decode($json_response, true);

// The string is decoded into a native PHP associative array.
// The client can now extract the token.
$authToken = $response_array['authToken']; // The variable $authToken now holds "xyz123"
```

### Part 4: The Authorized Folder Request (PHP -> Java `handleGetFolders`)

Now that the client is authenticated, it makes a **new** HTTP request to get the user's folders, using the token it just received.

**PHP Side (Conceptual):**
```php
$postData = [
    'action'    => 'getFolders',
    'authToken' => $authToken // The "xyz123" token we saved
];
$folder_json_response = $this->call_the_java_shim($postData);
```
This request hits the Java shim, which routes it to `handleGetFolders`. The first thing the method does is validate the token.

**Java Side (`handleGetFolders`):**
```java
    // The method retrieves the token sent by the client.
    String authTokenStr = request.getParameter("authToken"); // Value is "xyz123"
    
    // The shim validates the token. It likely finds it in the tokenCache 
    // that was populated during the handleAuth call.
    AuthToken authToken = getValidatedAuthToken(authTokenStr); 
    
    // Because the token is valid, the rest of the method executes,
    // retrieving folders for the user associated with this token.
```
This completes the full circle. The `authToken` acts as the "glue" that connects the initial login to all subsequent, authorized requests, proving to the shim for every request that the client has already been authenticated.

---

## 10. Update: Review of the Tested and Working Implementation

This section updates the walkthrough to reflect the new, fully implemented, and unit-tested version of the `ZPushShim.java` code. The previous sections described the architecture and the intended logic; this section describes the *actual* working code as verified by the test harness in the `/test` directory.

### Analysis of the Test Harness

The test suite in `/test` (orchestrated by `run_shim_tests.sh` and implemented in `test_shim_endpoints.py`) confirms the shim's API contract. It tests the following actions in sequence, creating a clear, verifiable workflow:
1.  `ping`: Checks for basic connectivity.
2.  `authenticate`: Logs in with a username/password to retrieve an `authToken`.
3.  `getfolders`: Uses the `authToken` to list folders.
4.  `getmessages`: Uses the `authToken` to list messages in a specific folder.
5.  `getmessage`: Uses the `authToken` to retrieve a single message.

The test harness proves that the `authToken` is the essential "glue" for the entire API, and its successful execution is a testament to the shim's core functionality.

### Review of Implemented Handlers in `ZPushShim.java`

The handler methods are no longer stubs; they contain the full production logic.

#### `handleAuth`
The implementation now correctly calls Zimbra's internal `prov.authAccount(...)` method.
*   **EAS Context:** It correctly builds the `authContext` map with the `eas` protocol, which is critical for allowing 2FA-enabled accounts to authenticate with app-specific passwords.
*   **Token Caching:** Upon successful authentication, the returned `AuthToken` is placed into the `tokenCache`. This is a performance optimization to speed up subsequent validation of the same token.
*   **JSON Response:** It returns a JSON object containing the `authToken` and `accountId`, exactly as the `test_shim_endpoints.py` script expects.

#### `getValidatedAuthToken`
This crucial helper method provides the security for every authorized endpoint.
*   It first checks the fast, in-memory `tokenCache` for the provided token string.
*   If the token is not in the cache, or if it has expired, it calls the core Zimbra `ZAuthToken.getAuthToken(...)` method to decode and verify the token's signature and validity.
*   This ensures that every API call that requires a token is properly authorized.

#### `handleGetFolders` & `handleGetMessages`
These methods now fully implement the data retrieval logic.
*   **Authorization:** They begin by calling `getValidatedAuthToken` to ensure the request is authorized.
*   **Scoped Data Access:** They retrieve the `Account` and `Mailbox` objects directly from the validated `AuthToken`. This is the key security feature that scopes the entire operation to the authenticated user.
*   **Safe Querying:** As seen in `handleGetMessages`, it safely builds a query string and passes it to Zimbra's `SearchParams` object. This delegates the query execution to Zimbra's core search functionality, which is robust and secure. It does not manually build queries with string concatenation.
*   **Data Transformation:** Both methods correctly transform the complex internal Zimbra objects (`Folder`, `Message`) into a `List` of simple `Map`s, which are then serialized to clean JSON for the PHP client. This matches the structure expected by the test harness.

The codebase has successfully evolved from a well-designed skeleton to a functional and tested implementation, with the test harness now serving as living documentation for its expected behavior.

