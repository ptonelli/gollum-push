# Wiki Backup Sidecar (Gollum)

A lightweight sidecar that watches a Gollum wiki’s Git repository and pushes to a remote over SSH whenever commits occur. It uses inotify (no polling) and does not create local commits (assumes Gollum keeps the repo clean).

## How it works
- Watches the repo’s .git directory with inotify and triggers a push when it changes.
- Uses SSH to connect to your remote (e.g., git@host:repo.git).
- Automatically adds the Git server host key to known_hosts on first run.

## Requirements
- A reachable SSH remote, e.g., git@code.example.com:wiki.git.
- SSH private key available in the container at $HOME/.ssh/id_rsa (0400 permissions).
- The sidecar image includes inotify-tools.
- The wiki directory is a Git repo (Gollum does this).

## Configuration (env)
- WIKI_DIR: Path to the wiki repository (default: /wiki).
- REMOTE_REPO: SSH remote URL (required), e.g., git@code.example.com:wiki.git.
- BRANCH: Branch to push (optional; defaults to current branch or master).
- DEBOUNCE: Seconds to batch inotify events (optional; default: 3).
- HOME: Should point to the directory where your SSH key is mounted (e.g., /home/git).

## Kubernetes: StatefulSet example

First, create a Secret with your private key (ensure it’s not passphrase-protected, or use an SSH agent approach):

```
kubectl create secret generic git-ssh-key \
  --from-file=id_rsa=./id_rsa
```

Then deploy a StatefulSet with the sidecar. The example below:
- Shares the same PersistentVolume with Gollum at /wiki.
- Mounts the SSH key at /home/git/.ssh/id_rsa with 0400 permissions.
- Sets HOME so the sidecar finds the key and writes known_hosts alongside it.

```
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: gollum
spec:
  serviceName: gollum
  replicas: 1
  selector:
    matchLabels:
      app: gollum
  template:
    metadata:
      labels:
        app: gollum
    spec:
      containers:
      - name: main
        image: gollumwiki/gollum:6.1
        volumeMounts:
        - name: wiki-data
          mountPath: /wiki
      - name: git-backup
        image: registry.example.com/wiki-backup:latest  # Your built image
        env:
          - name: HOME
            value: "/home/git"
          - name: WIKI_DIR
            value: "/wiki"
          - name: REMOTE_REPO
            value: "git@code.example.com:wiki.git"  # Your SSH remote
          # Optional:
          # - name: BRANCH
          #   value: "main"
          # - name: DEBOUNCE
          #   value: "3"
        volumeMounts:
          - name: wiki-data
            mountPath: /wiki
          - name: ssh-key
            mountPath: /home/git/.ssh/id_rsa
            subPath: id_rsa
            readOnly: true
      volumes:
        - name: ssh-key
          secret:
            secretName: git-ssh-key
            defaultMode: 0400
```

## Notes
- Permissions: SSH requires the private key to be 0400; defaultMode above enforces that.
- HOME and key location must match. If you mount the key under /root/.ssh/id_rsa, set HOME=/root or adjust paths accordingly.
- known_hosts is managed automatically via ssh-keyscan when the sidecar starts.
- No polling or SLEEP_TIME is used; inotify triggers pushes on commit events.

## Build/Push (example)
Use your private registry and optional namespace:

```
make REGISTRY=registry.example.com dockerx
```
