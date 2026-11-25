# Sightport

Sightport is a native macOS Kubernetes client that connects directly to kubeconfig contexts. It runs on macOS 14 or later.

Download the Sightport ZIP for Intel and Apple silicon Macs, unzip it, and move **Sightport.app** to Applications. [Latest GitHub release](https://github.com/nicholaspearson/sightport/releases/latest)

## Using Sightport

1. Install `kubectl`. Sightport checks the app’s PATH and common Homebrew and MacPorts locations.
2. Open Sightport. It reads contexts from `~/.kube/config`, or from the individual files in `KUBECONFIG` when that variable is present in the app’s environment. Use **Open kubeconfig** (⌘O) to add another file.
3. Click a context in the left rail to connect. You can also select a row to inspect it, then choose **Connect**, or double-click the row. Sightport uses that exact file and context to request the API version and makes the context active when the request succeeds. Your kubeconfig’s authentication method runs for this request.
4. Click a context’s star to favorite it, or use its shortcut menu in the rail. Favorites appear at the top of the rail and in the **Favorites** tab. Unavailable favorites retain their file and context name so they can reappear when the file is available.

After a successful connection, Sightport opens **Namespaces**. Double-click a namespace to view its pods. The connected navigator also includes **Nodes**, **Workloads**, and **Config**. Select a resource to inspect its fields, or open **Workloads → Overview** for counts by kind. Secrets and Config Maps show metadata and key counts.

The namespace selector applies to namespaced resources and the workload overview. It starts with the kubeconfig’s namespace, or `default`. Choose **All namespaces** to list objects across namespaces, or **Enter namespace…** to use a known namespace when your account cannot list namespaces. Cluster-scoped views are labeled **Cluster-wide**. Press ⌘R to refresh the current view.

- **Network** contains Services, Endpoint Slices, Endpoints, Ingresses, Ingress Classes and Network Policies. Expand **Gateway API** to browse gateway classes, gateways, routes and policies served by your cluster.
- **Network → Port Forwarding** lets you start and stop local TCP forwards to a pod or service. Choose **New Forward…**, enter a namespace, target and remote port, then start it. A blank local port lets kubectl choose one. The view shows the listening address on `127.0.0.1`. Forwards stay active while you browse other tabs and stop when you change clusters or close the window.
- **Storage** shows Persistent Volume Claims, Persistent Volumes and Storage Classes. **Events** shows recent activity, including the affected object, reason, message and last observation.
- **Helm → Releases** shows release status, revision, chart and application version. This view uses a local Helm 3 or 4 executable and the selected kubeconfig context.
- **Access Control** lists Service Accounts, Cluster Roles, Roles, Cluster Role Bindings and Role Bindings. Inspect a role for its rules or a binding for its role and subjects.
- **Custom Resources → Definitions** lists the types installed on the cluster. Double-click a definition or choose **View instances** to browse its objects in the appropriate scope.

Expand **Argo CD** to open its application health and sync dashboard, Applications, Application Sets, or Projects. Choose the namespace that holds your Argo CD resources, often `argocd`. Select an application on the dashboard to inspect it. **Settings → Repositories** and **Settings → Clusters** show registered connections from labeled Secrets in the selected scope. An account needs permission to list those Secrets. The tables display connection identity fields and omit credentials.

Expand **Karpenter** to browse cluster-wide Node Pools, Node Claims, and AWS EC2 Node Classes. Select a claim to inspect its readiness, instance type, capacity type, and zone. Click **Node Pool** or **Node** in the inspector to open the related object. Sightport uses the APIs served by the selected cluster and reports when a resource is unavailable.

In **Pods**, select a row to open its details on the right. Drag the divider to resize the table and details, or close the details pane to use the full width for the table. The pane shows the latest CPU and memory measurements, pod properties, and container states. Click a namespace, supported controller, or node to open the related resource. Click a column header to sort or check rows to copy their namespace-qualified names together.

Choose **View logs** in pod details or a pod’s action menu to open the log drawer beneath the table and details. Its tab shows the namespace and pod it follows as you select other rows. You can resize, collapse, or close the drawer independently. Pick a container, select **Previous instance** to inspect its last terminated instance, or refresh to fetch the latest output. Each request reads up to 200 lines and 256 KiB.

Choose **Open terminal** in pod details or the row menu to start an interactive shell using `kubectl exec`. A pod with one running container opens `/bin/sh` immediately. For multiple running containers, pick a container and shell, then click **Connect**. The shell must be installed in that container, and your context needs permission to use `pods/exec`. If the shell exits, its output stays visible and **Reconnect** starts a new session.

The drawer can hold logs and a terminal for each pod. Switching drawer tabs, collapsing the drawer, or browsing another resource keeps the shell session open. **Disconnect**, closing its terminal tab, closing the Pods workbench tab or window, and switching clusters end the corresponding sessions.

Sightport reads local context metadata at launch. Connecting and browsing resources use read-only requests with the chosen kubeconfig and context. Cluster data stays in memory and switching clusters clears the previous cluster’s tabs and results.

The app stores favorites and the last active context in `~/Library/Application Support/Sightport/context-preferences.json`. Older installations import their starred contexts, active selection, and referenced kubeconfig files.

Use **Sightport → Check for Updates…** to check the release feed. **Automatic Updates** in the same menu controls background checks and automatic installation. The app verifies signed releases using its embedded public key. [Release and signing guide](docs/updates.md)

## Development

Open `Sightport.xcodeproj` in Xcode, select the Sightport scheme, and press ⌘R. The app uses SwiftUI, AppKit, SwiftTerm for terminal emulation, and a local Swift package for context preferences and kubectl access.

```sh
swift test
xcodebuild -project Sightport.xcodeproj -scheme Sightport -configuration Release -derivedDataPath .build/Xcode build
open .build/Xcode/Build/Products/Release/Sightport.app
```
