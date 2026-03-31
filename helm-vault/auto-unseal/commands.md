# AutoUseal on-prem preparation

- Init vault

    ```shell
    POD=$(kubectl -n vault get pods -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')
    kubectl exec -it -n vault $POD -- /bin/sh /
    vault operator init -key-shares=5 -key-threshold=3 -format=json 

    ```

- Save output to vault-init.json
- Convert JSON to YAML

    ```shell
    yq -P < vault-init.json > vault-init.yaml
    ```

- Convert JSON to Secret

    ```shell
    kubectl create secret generic vault-init \
  --from-file=vault-init.yaml \
  -n vault \
  --dry-run=client \
  -o yaml | tee vault-init-secret.yaml
    ```

- Encrypt with SOPS

    ```shell
    sops -e -i vault-init-secret.yaml
    ```

- Check decrypt with Kustomize

    ```shell
    export SOPS_AGE_KEY=AGE-SECRET-KEY-ABCDEFGH...; kustomize build --enable-alpha-plugins --enable-exec .
    ```
