import * as net from 'node:net'

// The Mac reaches the local cluster on *.localhost:8080 (host port 8080 → Traefik :80), and Keycloak's issuer
// carries that port, so the browser in the runner pod must use the same URLs. Chromium maps *.localhost to
// loopback; this proxy carries loopback:8080 to Traefik's service.
const TRAEFIK_HOST = 'traefik.kube-system.svc.cluster.local'
const TRAEFIK_PORT = 80

export async function startLocalProxy(): Promise<net.Server> {
  const server = net.createServer((client) => {
    const upstream = net.connect(TRAEFIK_PORT, TRAEFIK_HOST)
    client.pipe(upstream)
    upstream.pipe(client)
    client.on('error', () => upstream.destroy())
    upstream.on('error', () => client.destroy())
  })
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(8080, '127.0.0.1', () => resolve())
  })
  return server
}
