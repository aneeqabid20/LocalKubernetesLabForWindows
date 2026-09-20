@{
    Ubuntu = @{
        Release = "24.04"
    }

    Kubernetes = @{
        Repo35 = "https://pkgs.k8s.io/core:/stable:/v1.35/deb/"
        Repo34 = "https://pkgs.k8s.io/core:/stable:/v1.34/deb/"

        PackageVersion35 = "1.35.8-1.1"
        PackageVersion34 = "1.34.11-1.1"

        AptKeySha256 = "5c463ffcfcb24088da4b049ac7b2c7b61dd9d6a7fa4f24e74eb0a533c53bfa17"
    }

    ContainerRuntime = @{
        ContainerdPackage = "containerd"
        ContainerdVersion = "2.2.1-0ubuntu1~24.04.3"

        RuncPackage = "runc"
        RuncVersion = "1.3.4-0ubuntu1~24.04.1"
    }

    Crictl = @{
        Controller = @{
            Version = "1.35.0"
            Sha256  = "53f836ba94d4d4b5ac2a1d1df6ca7e7159ec994c8d8ea834469910cd5f7de4c6"
        }

        Node01 = @{
            Version = "1.35.0"
            Sha256  = "53f836ba94d4d4b5ac2a1d1df6ca7e7159ec994c8d8ea834469910cd5f7de4c6"
        }

        Node02 = @{
            Version = "1.34.0"
            Sha256  = "9b49f0acab34e9f0eff218b493d92688f53200582ebc67d8cc01e9770da5c955"
        }
    }

    CiliumCLI = @{
        Version = "0.20.0"
        Sha256  = "8336dd43466badff49099e352567068f406e75f666760b128b525f114b4f7456"
    }

    Cilium = @{
        Version = "1.20.1"
    }
}