# Sightport

Sightport is a native macOS Kubernetes client that connects directly to kubeconfig contexts. It runs on macOS 14 or later.

Download the Sightport ZIP for Intel and Apple silicon Macs, unzip it, and move **Sightport.app** to Applications. [Latest GitHub release](https://github.com/nicholaspearson/sightport/releases/latest)

## Using Sightport

1. Open Sightport. It reads contexts from `~/.kube/config`, or from the individual files in `KUBECONFIG` when that variable is present in the app’s environment. Use **Open kubeconfig** (⌘O) to add another file.
2. Open **Contexts** to see the available contexts. Double-click a row to connect, or select it and choose **Connect**. Sightport uses that exact file and context to request the API version and makes the context active when the request succeeds. Your kubeconfig’s authentication method runs for this request.
3. The left rail shows the connected context and your favorites. Click a context’s star in the table to favorite it. Right-click a rail entry for **Connect** or **Disconnect**. Disconnecting closes that context’s cluster tabs, terminals and port forwards. A favorite stays in the rail for the next connection.
4. Right-click a context in the table or rail and choose **Remove from Sightport…** to remove it from this workspace. Removing a connected context closes its cluster sessions. Your kubeconfig remains available to other tools. To restore removed contexts from a file, reopen it with **Open kubeconfig** (⌘O).

After a successful connection, Sightport opens **Namespaces**. Double-click a namespace to view its pods. The connected navigator also includes **Nodes**, **Workloads**, and **Config**. Select a resource to inspect its fields, or open **Workloads → Overview** for counts by kind.

Browsing resources reuses one italicized preview tab. Selecting a row, searching, sorting, or opening logs keeps the tab open. Double-click the tab or choose **Keep Tab Open** from its context menu to keep it explicitly.

Double-click a **Node** to open its inspector on the right and view scheduling, conditions, addresses, capacity and labels. The inspector header offers its YAML manifest, **Drain node…** and **Delete node…**. Draining cordons the node and requests pod evictions subject to disruption budgets. Check the node’s scheduling state after a drain.

In **Deployments**, choose **View Logs** and use the **Pod** and **Container** selectors in the bottom drawer. **Restart Rollout…** is available on Deployments, DaemonSets and StatefulSets. Under **Cron Jobs**, **Start Job…** creates a one-off run. Under **Jobs**, **Start Job…** resumes a suspended Job and **Run Again…** creates a new Job from the selected run.

In **Config → Config Maps**, select a Config Map to read its keys and values beside the list. Expand **Labels** or **Annotations** to inspect its metadata. Text values preserve their formatting, and binary values are shown as Base64.

In **Config → Secrets**, select a Secret to open its properties, related events, and data keys beside the list. Values start hidden. Use the eye beside a key to reveal its value or hide it again. Binary values are available as Base64. Listing Secrets and reading an individual Secret use the permissions of the connected context.

The namespace selector applies to namespaced resources and the workload overview. It starts with the kubeconfig’s namespace, or `default`. Choose **All namespaces** to list objects across namespaces, or **Enter namespace…** to use a known namespace when your account cannot list namespaces. Cluster-scoped views are labeled **Cluster-wide**.

The visible Kubernetes resource list follows watch events. Pods appear and disappear automatically, and status, readiness, restarts, and selected details update in place. Sightport reconnects when a watch ends. If a watch is unavailable, it refreshes the list every five seconds while retrying. The workload overview and Helm releases refresh every 15 seconds. Switching views, minimizing, or closing the window stops the corresponding reads. Press ⌘R for an immediate refresh.

- **Network** contains Services, Endpoint Slices, Endpoints, Ingresses, Ingress Classes and Network Policies. Expand **Gateway API** to browse gateway classes, gateways, routes and policies served by your cluster.
- **Network → Port Forwarding** lets you start and stop local TCP forwards to a pod or service. Choose **New Forward…**, enter a namespace, target and remote port, then start it. A blank local port assigns an available port. The view shows the listening address on `127.0.0.1`. Forwards stay active while you browse other tabs and stop when you change clusters or close the window.
- **Storage** shows Persistent Volume Claims, Persistent Volumes and Storage Classes. **Events** shows recent activity, including the affected object, reason, message and last observation.
- **Helm → Releases** shows release status, revision, chart and application version. This view uses a local Helm 3 or 4 executable and the selected kubeconfig context.
- **Access Control** lists Service Accounts, Cluster Roles, Roles, Cluster Role Bindings and Role Bindings. Select a Service Account to read its annotations, including an IAM role ARN when configured. Inspect a role for its rules or a binding for its role and subjects.
- Expand **Custom Resources** to browse the cluster’s installed custom resource types by API group. Select a kind to see its objects. Namespaced types follow the namespace selector. **Definitions** opens the full CRD table, where you can also double-click a definition to view its instances.

Expand **Argo CD** to open its application health and sync dashboard, Applications, Application Sets, or Projects. Choose the namespace that holds your Argo CD resources, often `argocd`. Select an application on the dashboard to inspect it. **Settings → Repositories** and **Settings → Clusters** show registered connections from labeled Secrets in the selected scope. An account needs permission to list those Secrets. The tables display connection identity fields and omit credentials.

Expand **Karpenter** to browse cluster-wide Node Pools, Node Claims, and AWS EC2 Node Classes. Select a claim to inspect its readiness, instance type, capacity type, and zone. Click **Node Pool** or **Node** in the inspector to open the related object. Sightport uses the APIs served by the selected cluster and reports when a resource is unavailable.

In **Pods**, select a row to open its details on the right. Choose **View YAML manifest** in the inspector toolbar to read the full pod object. Drag the divider to resize the table and details, or close the details pane to use the full width for the table. Expand a container to inspect its image, runtime state, environment variables and their sources. Expand **Labels** in pod properties to see the pod’s label keys and values. When the cluster serves pod metrics, Sightport refreshes CPU and memory measurements every 15 seconds. Click a namespace, supported controller, or node to open the related resource. Click a column header to sort or check rows to copy their namespace-qualified names together.

Choose **Terminate Pod…** from the row menu or the trash button in pod details. The confirmation identifies the pod, namespace, context and any controlling workload. Termination uses the pod’s configured grace period and requires permission to delete pods in its namespace. Its controller may create a replacement.

Choose **View logs** in pod details or a pod’s action menu to open the log drawer beneath the table and details. Its tab shows the namespace and pod it follows as you select other rows. You can resize, collapse, or close the drawer independently. The visible logs drawer refreshes the current container’s output every three seconds. Select **Previous instance** for a snapshot of its last terminated instance, or use Refresh for an immediate read. Each request reads up to 200 lines and 256 KiB.

Choose **Open terminal** in pod details or the row menu to start an interactive shell through the Kubernetes exec API. A pod with one running container opens `/bin/sh` immediately. For multiple running containers, pick a container and shell, then click **Connect**. The shell must be installed in that container, and your context needs permission to use `pods/exec`. If the shell exits, its output stays visible and **Reconnect** starts a new session.

The drawer can hold logs and a terminal for each pod. Switching drawer tabs, collapsing the drawer, or browsing another resource keeps the shell session open. **Disconnect**, closing its terminal tab, closing the Pods workbench tab or window, and switching clusters end the corresponding sessions.

The app bundles Kubernetes’ client-go SDK in a native helper. The helper reads local context metadata at launch and connects directly to the API server for the selected context. Kubeconfigs that use an external credential provider, such as AWS CLI, still need that provider installed. Connecting and browsing resources use read-only requests with the chosen kubeconfig and context. Cluster data stays in memory and switching clusters clears the previous cluster’s tabs and results.

The app stores favorites and the last active context in `~/Library/Application Support/Sightport/context-preferences.json`. Older installations import their starred contexts, active selection, and referenced kubeconfig files.

Use **Sightport → Check for Updates…** to check the release feed. **Automatic Updates** in the same menu controls background checks and automatic installation. The app verifies signed releases using its embedded public key. [Release and signing guide](docs/updates.md)

## Development

Install Go 1.26 or later and open `Sightport.xcodeproj` in Xcode. Select the Sightport scheme and press ⌘R. Xcode builds the SwiftUI app and its native Kubernetes helper for the selected architectures. The helper and its pinned client-go dependencies live in `Tools/kube-client`. Go is only needed to build from source.

```sh
swift test
go -C Tools/kube-client test ./...
xcodebuild -project Sightport.xcodeproj -scheme Sightport -configuration Release -derivedDataPath .build/Xcode build
open .build/Xcode/Build/Products/Release/Sightport.app
```
