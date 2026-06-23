# gt-core-labs dev loop on Talos. Build from source -> push cluster TLS registry
# -> helm deploy. Edit code in gt-core/ gt-web/ gt-docs/ -> Tilt rebuilds+redeploys.
allow_k8s_contexts('admin@gt-core')

docker_build('registry.codecsrayo.com/gt-core-mcp-server', 'gt-core',
             dockerfile='gt-core/Dockerfile.embeddings')
docker_build('registry.codecsrayo.com/gt-core-orchd', 'gt-core',
             dockerfile='gt-core/Dockerfile.orchd')
docker_build('registry.codecsrayo.com/gt-web', 'gt-web', dockerfile='gt-web/Dockerfile')
docker_build('registry.codecsrayo.com/gt-docs', 'gt-docs', dockerfile='gt-docs/Dockerfile')

k8s_yaml(helm(
    'gt-app-proxy/chart/gt',
    name='gt',
    namespace='gt',
    values=['gt-app-proxy/values-secret.yaml', 'dev/dev-values.yaml'],
))
