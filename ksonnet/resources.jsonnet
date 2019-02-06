
//
// Definition for VPN resources on Kubernetes.
//

// Import KSonnet library.
local k = import "ksonnet.beta.2/k.libsonnet";

// Short-cuts to various objects in the KSonnet library.
local depl = k.extensions.v1beta1.deployment;
local container = depl.mixin.spec.template.spec.containersType;
local containerPort = container.portsType;
local mount = container.volumeMountsType;
local volume = depl.mixin.spec.template.spec.volumesType;
local resources = container.resourcesType;
local env = container.envType;
local svc = k.core.v1.service;
local svcPort = svc.mixin.spec.portsType;
local svcLabels = svc.mixin.metadata.labels;
local externalIp = svc.mixin.spec.loadBalancerIp;
local svcType = svc.mixin.spec.type;
local secretDisk = volume.mixin.secret;
local pvcVol = volume.mixin.persistentVolumeClaim;
local pvc = k.core.v1.persistentVolumeClaim;
local sc = k.storage.v1.storageClass;

// Resources which provide the address allocator.  Address allocator is
// a container which provides an HTTPS interface for programatic use.
// It can provide a list of allocated addresses, or given a device name,
// provide the address, allocating a new one of not allocated.  Although
// it is a web interface, it is protected by keys derived from the VPN CA key.
local addrAlloc(config) = {

    name: "addr-alloc",
    addrAllocVersion:: import "addr-alloc-version.jsonnet",
    images: [config.containerBase + "/addr-alloc:" + self.addrAllocVersion],
    
    local ports = [
        containerPort.newNamed("addr-alloc", 443)
    ],
    local volumeMounts = [
        mount.new("allocator-svc-creds", "/key") + mount.readOnly(true),
        mount.new("addr-alloc-data", "/addresses")
    ],
    local containers = [
        container.new("addr-alloc", self.images[0]) +
            container.ports(ports) +
            container.volumeMounts(volumeMounts) +
            container.mixin.resources.limits({
                memory: "64M", cpu: "1.0"
            }) +
            container.mixin.resources.requests({
                memory: "64M", cpu: "0.05"
            })
    ],
    // Volumes - this invokes a secret containing the cert/key
    local volumes = [

        // probe-svc-creds secret
        volume.name("allocator-svc-creds") +
            secretDisk.secretName("allocator-svc-creds"),

        volume.name("addr-alloc-data") + pvcVol.claimName("addr-alloc-data")

    ],

    // Deployments
    deployments: [
        depl.new("addr-alloc", 1, containers,
                 {app: "addr-alloc", component: "access"}) +
            depl.mixin.spec.template.spec.volumes(volumes) +
            depl.mixin.metadata.namespace(config.namespace)
    ],
    // Ports used by the service.
    local servicePorts = [
        svcPort.newNamed("addr-alloc", 443, 443) + svcPort.protocol("TCP")
    ],
    // Service
    services:: [

        svc.new("addr-alloc", {app: "addr-alloc"}, servicePorts) +

           // Load-balancer and external IP address
           externalIp(config.addresses.addrAlloc) + svcType("LoadBalancer") +

           // This traffic policy ensures observed IP addresses are the external
           // ones
           svc.mixin.spec.externalTrafficPolicy("Local") +

           // Label
           svcLabels({app: "addr-alloc", component: "access"}) +

           svc.mixin.metadata.namespace(config.namespace)

    ],

    storageClasses:: [
        sc.new() + sc.mixin.metadata.name("addr-alloc") +
            sc.mixin.metadata.namespace(config.namespace) +
            config.storageParams.hot +
            { reclaimPolicy: "Retain" }
    ],

    pvcs:: [
        pvc.new() + pvc.mixin.metadata.name("addr-alloc-data") +
            pvc.mixin.spec.storageClassName("addr-alloc") +
            pvc.mixin.spec.accessModes(["ReadWriteOnce"]) +
            pvc.mixin.metadata.namespace(config.namespace) +
            pvc.mixin.spec.resources.requests({
                    storage: "10Gi"
            })
    ],
    
    resources:
        if config.options.includeAddrAlloc then
            self.deployments + self.services + self.storageClasses + self.pvcs
        else [],

    diagram: if config.options.includeAddrAlloc then [
	"addralloc [label=\"address allocator\"]"
    ] else []

};

// OpenVPN service.  Provides an OpenVPN VPN on port 443, and delivers captured
// packets to the probe service.
local openvpnSvc(config) = {
    
    name: "openvpn-svc",
    cyberprobeSyncVersion:: import "cyberprobe-sync-version.jsonnet",
    cyberprobeVersion:: import "cyberprobe-version.jsonnet",
    openvpnServiceVersion:: import "version.jsonnet",
    images: [
    	config.containerBase + "/vpn-svc:" + self.openvpnServiceVersion,
    	config.containerBase + "/cyberprobe-sync:" + self.cyberprobeSyncVersion,
	"cybermaggedon/cyberprobe:" + self.cyberprobeVersion 
    ],

    // Ports.
    local ports = [
        containerPort.newNamed("openvpn", 443)
    ],
    // Volume mounts
    local openvpnVolumeMounts = [
        mount.new("vpn-svc-creds", "/key") + mount.readOnly(true),
        mount.new("shared-config", "/config"),
        mount.new("dev-net", "/dev/net")
    ],
    local cyberprobeCmd = "cyberprobe /config/cyberprobe.cfg",
    // Init containers
    local initContainers = [

	// InitContainer which creates the /dev/net/tun device
        container.new("init-dev-net", self.images[0]) +
            container.command(["sh", "-c",
			       "test -d /dev/net || mkdir /dev/net; test -e /dev/net/tun || mknod /dev/net/tun c 10 200"]) +
	    container.volumeMounts([
		mount.new("dev-net", "/dev/net")
	    ]),

	// InitContainer which creates /config/clients
        container.new("init-config", self.images[0]) +
            container.command(["sh", "-c",
			       "test -d /config/clients || mkdir /config/clients;chown nobody /config/clients; chmod 755 /config/clients"]) +
	    container.volumeMounts([
		mount.new("shared-config", "/config")
	    ]),

	// InitContainer which configures the iptables for masquerading
	container.new("init-masq", self.images[0]) +
            container.command(["sh", "-c",
			       "iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"]) +
            container.mixin.securityContext.capabilities.add("NET_ADMIN"),
    ],
    // Containers
    local containers = [
	
	// NET_ADMIN allows VPN service to create and use the /dev/tun*
	// devices.
        container.new(self.name, self.images[0]) +
            container.ports(ports) +
            container.volumeMounts(openvpnVolumeMounts) +
            container.mixin.resources.limits({
                memory: "512M", cpu: "1.5"
            }) +
            container.mixin.resources.requests({
                memory: "512M", cpu: "0.5"
            }) +
            container.mixin.securityContext.capabilities.add("NET_ADMIN"),

        container.new("sync", self.images[1]) +
	    container.volumeMounts([
		mount.new("shared-config", "/config")
	    ]) +
            container.mixin.resources.limits({
                memory: "64M", cpu: "0.1"
            }) +
            container.mixin.resources.requests({
                memory: "64M", cpu: "0.1"
            }),

	// Cyberprobe needs to sleep before starting so that the /dev/tun
	// device is in place before cyberprobe accesses it, because it
	// doesn't retry on device open failure.
        container.new("cyberprobe", self.images[2]) +
	    container.volumeMounts([
                mount.new("vpn-probe-creds", "/probe-creds"),
		mount.new("shared-config", "/config"),
		mount.new("dev-net", "/dev/net")
	    ]) +
            container.mixin.resources.limits({
                memory: "128M", cpu: "0.1"
            }) +
            container.mixin.resources.requests({
                memory: "128M", cpu: "0.1"
            }) +
            container.command(["sh", "-c", cyberprobeCmd]) +
            container.mixin.securityContext.capabilities.add("NET_ADMIN")

    ],
    // Volumes - this invokes a secret containing the cert/key
    local volumes = [

        // vpn-svc-creds secret
        volume.name("vpn-svc-creds") +
            secretDisk.secretName("vpn-svc-creds"),

        // vpn-probe-creds secret
        volume.name("vpn-probe-creds") +
            secretDisk.secretName("vpn-probe-creds"),

        // shared config
        volume.fromEmptyDir("shared-config"),

        // /dev/net
        volume.fromEmptyDir("dev-net"),

    ],
    // Deployments
    deployments:: [
        depl.new("openvpn-service", config.openvpnService["replicas"],
		 containers,
                 {app: "openvpn-service", component: "access"}) +
            depl.mixin.spec.template.spec.volumes(volumes) +
            depl.mixin.spec.template.spec.initContainers(initContainers) +
            depl.mixin.metadata.namespace(config.namespace)
    ],
    // Ports used by the service.
    local servicePorts = [
        svcPort.newNamed("openvpn", 443, 443) + svcPort.protocol("TCP")
    ],

    // Service
    services:: [
        svc.new("openvpn", {app: "openvpn-service"}, servicePorts) +

           // Load-balancer and external IP address
           externalIp(config.addresses.openvpnService) + svcType("LoadBalancer") +

           // This traffic policy ensures observed IP addresses are the external
           // ones
           svc.mixin.spec.externalTrafficPolicy("Local") +

           // Label
           svcLabels({app: "openvpn", component: "access"}) +

           svc.mixin.metadata.namespace(config.namespace)
    ],

    resources:
        if config.options.includeOpenvpn then
            self.deployments + self.services
        else [],
    
    createCommands:
        if config.options.includeOpenvpn then
            [
                ("gcloud compute --project \"%s\" disks create \"vpn-ca-0000\"" +
                 " --size \"%s\" --zone \"%s\" --type \"%s\"") %
                    [config.project, config.vpnCaDiskSize,
                     config.zone, config.vpnCaDiskType]
            ]
        else [],

    deleteCommands:
        if config.options.includeOpenvpn then
            [
         ("gcloud compute --project \"%s\" disks delete --zone \"%s\" " +
              "\"vpn-ca-0000\"") %
         [config.project, config.zone]
            ]
        else [],

    diagram: if config.options.includeOpenvpn then [
	"subgraph cluster_3 { label=\"OpenVPN\nservice\"",
	"openvpnsvc [label=\"openvpn-service\"]",
	"cyberprobe",
	"cyberprobesync [label=\"cyberprobe-sync\"]",
	"}",
	"openvpnsvc -> cyberprobe",
	"openvpnsvc -> addralloc",
	"cyberprobe -> probesvc"
    ] else []

};

[addrAlloc, openvpnSvc]
