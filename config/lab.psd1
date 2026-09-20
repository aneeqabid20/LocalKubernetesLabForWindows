@{
    LabName = "LocalKubernetesLabForWindows"

    WSL = @{
        Controller = "k8slab-controller"
        Node01     = "k8slab-node01"
        Node02     = "k8slab-node02"
    }

    Nodes = @{
        Controller = @{
            Hostname   = "k8slab-controller"
            FQDN       = "k8slab-controller.k8slab.local"
            IP         = "192.168.250.1"
            Kubernetes = "1.35.8"
        }

        Node01 = @{
            Hostname   = "k8slab-node01"
            FQDN       = "k8slab-node01.k8slab.local"
            IP         = "192.168.250.2"
            Kubernetes = "1.35.8"
            Namespace  = "k8slab-node01-ns"
        }

        Node02 = @{
            Hostname   = "k8slab-node02"
            FQDN       = "k8slab-node02.k8slab.local"
            IP         = "192.168.250.3"
            Kubernetes = "1.34.11"
            Namespace  = "k8slab-node02-ns"
        }
    }

    Network = @{
        Bridge        = "k8slab-br0"
        Subnet        = "192.168.250.0/24"
        PodCIDR       = "10.244.0.0/16"
        ServiceCIDR   = "10.96.0.0/12"
        DNSDomain     = "cluster.local"

        Node01HostVeth = "veth-n01-host"
        Node02HostVeth = "veth-n02-host"
    }

    Kubernetes = @{
        ControllerVersion = "1.35.8"
        Node01Version      = "1.35.8"
        Node02Version      = "1.34.11"
        ContainerRuntime   = "containerd"
    }

    Cilium = @{
        Version                = "1.20.1"
        RoutingMode            = "native"
        IPAM                   = "kubernetes"
        IPv4NativeRoutingCIDR  = "10.244.0.0/16"
        AutoDirectNodeRoutes   = $true
        KubeProxyReplacement   = $false
        HubbleRelay            = $true
        HubbleUI               = $true
    }

    WSLKernel = @{
        InotifyMaxUserInstances = 1024
    }
}