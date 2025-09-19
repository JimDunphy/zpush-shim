# Z-Push Shim Newcomer Guide

Welcome to the Z-Push Shim project! This guide gives you a quick tour of the repository, highlights the most important components, and points you toward the best resources for learning more. Every section includes links back to the canonical sources on GitHub so you can jump directly into the code or documentation.

## 1. Understand the problem space

* **Project overview:** Start with the [main README](../README.md) for the administrator-facing story, supported features, and a safe deploy/undeploy workflow.
* **Shim architecture:** Read [README-SHIM.md](../README-SHIM.md) for the Java-focused explanation of how the shim accelerates Z-Push by calling internal Zimbra APIs.
* **Deep dive docs:** When you are ready for implementation details, move on to [INTERNALS-SHIM.md](../INTERNALS-SHIM.md) and the [code walkthrough](../code-walkthrough.md).

## 2. Repository tour

The repository is organized around a clear split between Java sources, deployment tooling, documentation, and smoke tests.

| Area | What it contains | Jump in |
| --- | --- | --- |
| Extension code | The Java classes that register the shim extension, handle requests, and provide developer mocks | [`com/zimbra/zpush/shim/`](../com/zimbra/zpush/shim) |
| Build tooling | Ant targets for compiling the JAR | [`build.xml`](../build.xml) |
| Deployment helpers | Scripts for building, deploying, and verifying the shim on a Zimbra host | [`deploy-shim.sh`](../deploy-shim.sh) |
| Container stack | Docker resources for running the Z-Push frontend and applying nginx templates | [`nginx/`](../nginx) (see [`manage.sh`](../nginx/manage.sh) and [`entrypoint.sh`](../nginx/entrypoint.sh)) |
| Documentation | Supplemental guides covering installation, architecture, and supporting services | [`docs/`](.) |
| Test harness | Python-based smoke tests that exercise the shim endpoints | [`test/`](../test) (entry point: [`run_shim_tests.sh`](../test/run_shim_tests.sh)) |

## 3. Key classes and entry points

* **Extension bootstrap:** [`ZPushShimExtension.java`](../com/zimbra/zpush/shim/ZPushShimExtension.java) registers the servlet with mailboxd when the extension loads.
* **Request handler:** [`ZPushShimHandler.java`](../com/zimbra/zpush/shim/ZPushShimHandler.java) routes HTTP actions (authenticate, ping, folder/message retrieval) and chooses between real Zimbra APIs or compatibility mocks at runtime.
* **Compatibility layer:** [`CompatCore.java`](../com/zimbra/zpush/shim/CompatCore.java) returns deterministic test data for development mode.
* **Standalone dev server:** [`DevServer.java`](../com/zimbra/zpush/shim/DevServer.java) exposes the shim endpoints locally so you can experiment without a full Zimbra deployment.

## 4. Build and deploy workflow

1. **Build the shim off-box.** Use Ant (`ant clean jar`) or the wrapper script ([`deploy-shim.sh --build`](../deploy-shim.sh)) to compile the extension JAR on a build machine.
2. **Deploy to the mailbox server.** Copy the artifact to your Zimbra host and run [`deploy-shim.sh --deploy`](../deploy-shim.sh) (or `--all` for build + deploy + verify) to install it safely.
3. **Enable the shim in Z-Push.** Update your Z-Push configuration per the [installation guide](../INSTALL.md) and, if you use the container, manage it with [`nginx/manage.sh`](../nginx/manage.sh).
4. **Verify functionality.** Run the smoke tests via [`test/run_shim_tests.sh`](../test/run_shim_tests.sh) or the Make targets described in the [Makefile](../Makefile).

## 5. Learning path for new contributors

1. **Get familiar with Z-Push and Zimbra extensions.** Read the [installation instructions](../INSTALL.md) and the docs under [`docs/`](.) to understand the operational context.
2. **Experiment locally.** Launch the standalone server with [`DevServer.java`](../com/zimbra/zpush/shim/DevServer.java) (via `make run-dev`) and run the mock-backed tests to see the shim in action.
3. **Trace production flows.** Consult [`docs/zimbra-nginx-layout-and-zpush.md`](zimbra-nginx-layout-and-zpush.md) and [`docs/Z-PUSH-NGINX-ROUTING.md`](Z-PUSH-NGINX-ROUTING.md) to understand how requests travel through nginx, the container, and the shim.
4. **Plan extensions.** Explore [`docs/Zimbra-Calls.md`](Zimbra-Calls.md) and [`docs/PROTOCOL_AUTH_BEHAVIOR.md`](PROTOCOL_AUTH_BEHAVIOR.md) when designing new endpoints or authentication flows.

## 6. Where this guide lives

Save this guide as `docs/NEWCOMER-GUIDE.md` so it sits alongside the rest of the documentation set. From there, add a short link in [`README.md`](../README.md) or the docs index if you want to advertise it as the first stop for new contributors.

