import { test, expect, type Browser, type Page, type APIResponse } from '@playwright/test'
import * as fs from 'node:fs'
import { startLocalProxyIfNeeded } from './local-proxy'

// LOCAL-CLUSTER Z-1: cluster `local-mac` is titan-incus, and template sync runs against real Incus on arm64.
// Runs INSIDE the titan-regression runner of the local cluster, with lib/local-proxy.ts of titan-regression beside it.
// mac/scripts/join-cluster.sh (up.sh) configured the cluster and made titan-incus trust Titan: nothing is registered here.
// Never prints a credential or a bearer token.
const API = process.env.API_BASE_URL || 'http://api.localhost:8080'
const ADMIN = process.env.ADMIN_BASE_URL || 'http://admin.localhost:8080'
const RESULTS = process.env.RESULTS_DIR || 'results'
const need = (k: string) => {
  const v = process.env[k]
  if (!v) throw new Error(`${k} is not set — the runner injects it`)
  return v
}

const CLUSTER = 'local-mac'

async function login(page: Page, host: string, user: string, password: string) {
  await page.goto(host + '/', { waitUntil: 'domcontentloaded' })
  const signIn = page.getByRole('button', { name: /sign in|log ?in|đăng nhập/i }).first()
  const signInVisible = await signIn.isVisible().catch(() => false)
  if (signInVisible) {
    await signIn.click().catch(() => {})
  }
  const username = page.locator('#username, input[name="username"]').first()
  await username.waitFor({ state: 'visible', timeout: 45_000 })
  await username.fill(user)
  await page.locator('#password, input[name="password"]').first().fill(password)
  await page.locator('#kc-login, button[type="submit"], input[type="submit"]').first().click()
  await page.waitForURL(new RegExp(new URL(host).host.replace(/\./g, '\\.')), { timeout: 45_000 })
  await page.getByRole('navigation').or(page.getByRole('heading').first()).first()
    .waitFor({ state: 'visible', timeout: 45_000 })
}

async function tokenFrom(page: Page): Promise<string> {
  const token = await page.evaluate(() => {
    for (const store of [sessionStorage, localStorage]) {
      for (let i = 0; i < store.length; i++) {
        const k = store.key(i)!
        if (!k.startsWith('oidc.user:')) continue
        const v = JSON.parse(store.getItem(k) || '{}')
        if (v.access_token) return v.access_token as string
      }
    }
    return ''
  })
  expect(token, 'a bearer token must be readable from the session').not.toEqual('')
  return token
}

async function expectCode(res: APIResponse, status: number) {
  const body = await res.text()
  expect(res.status(), `${res.url()} → ${body.slice(0, 300)}`).toBe(status)
  return body
}

let browserRef: Browser | null = null
let admin: Record<string, string> = {}
const lines: string[] = []
const log = (line: string) => {
  lines.push(line)
  console.log(line)
  fs.writeFileSync(`${RESULTS}/z1-cluster-${CLUSTER}.txt`, lines.join('\n') + '\n')
}

// The access token lives minutes and the waits below are longer: sign in again in a fresh context.
async function signInAdmin(screenshot?: string): Promise<void> {
  if (browserRef === null) {
    throw new Error('signInAdmin needs the browser of a test')
  }
  const context = await browserRef.newContext({ viewport: { width: 1440, height: 900 } })
  const page = await context.newPage()
  await login(page, ADMIN, process.env.ADMIN_TEST_USERNAME || 'admin-test', need('ADMIN_TEST_PASSWORD'))
  admin = { Authorization: `Bearer ${await tokenFrom(page)}` }
  if (screenshot !== undefined) {
    await page.screenshot({ path: `${RESULTS}/${screenshot}` })
  }
  await context.close()
}

test.beforeAll(async () => {
  await startLocalProxyIfNeeded(ADMIN)
})

test('Z-1 — cluster local-mac is titan-incus, template sync on arm64', async ({ browser, request }) => {
  test.setTimeout(45 * 60_000)
  browserRef = browser
  await signInAdmin('z1-admin-signed-in.png')

  // Z1-1: the configured clusters are local-mac only.
  const clusters = JSON.parse(await expectCode(await request.get(`${API}/v1/clusters`), 200))
  log(`Z1-1 clusters ${JSON.stringify(clusters)}`)
  expect(clusters.map((z: { id: string }) => z.id)).toEqual([CLUSTER])

  // Z1-2: Titan's client certificate, the one join-cluster.sh put in the Secret.
  const certificate = JSON.parse(await expectCode(
    await request.get(`${API}/v1/admin/clusters/client-certificate`, { headers: admin }), 200))
  log(`Z1-2 client certificate fingerprint ${certificate.fingerprint}`)

  // Z1-3: the cluster comes from config, with the server fingerprint read from titan-incus and its provider settings.
  type Cluster = { clusterId: string, endpoint: string, serverFingerprint: string, providerSettings: { ovnUplinkNetwork: string | null, storagePool: string | null } }
  const configured: Cluster[] = JSON.parse(await expectCode(await request.get(`${API}/v1/admin/clusters`, { headers: admin }), 200))
  const cluster = configured.find((c) => c.clusterId === CLUSTER)
  expect(cluster, `cluster ${CLUSTER} is not configured`).toBeDefined()
  expect(cluster!.serverFingerprint).toMatch(/^[0-9a-f]{64}$/)
  expect(cluster!.providerSettings).toMatchObject({ ovnUplinkNetwork: 'ovnup', storagePool: 'default' })
  log(`Z1-3 cluster ${CLUSTER} configured: ${cluster!.endpoint} ${cluster!.serverFingerprint}`)

  // Z1-4: titan-incus answers trusted (join-cluster.sh trusted Titan); a wait covers a control plane still restarting.
  let firstError = ''
  let trustedAt = 0
  const waitStart = Date.now()
  while (Date.now() - waitStart < 15 * 60_000) {
    let res = await request.post(`${API}/v1/admin/clusters/test`, {
      headers: admin, data: { endpoint: cluster!.endpoint, serverFingerprint: cluster!.serverFingerprint },
    })
    if (res.status() === 401) {
      await signInAdmin()
      continue
    }
    const result = JSON.parse(await expectCode(res, 200))
    if (result.ok === true) {
      trustedAt = Date.now()
      log(`Z1-4 test ok latencyMs=${result.latencyMs} after ${Math.round((trustedAt - waitStart) / 1000)}s`)
      break
    }
    if (firstError === '') {
      firstError = result.error
      log(`Z1-4 test before trust: ok=false error=${JSON.stringify(result.error)}`)
    }
    await new Promise((resolve) => setTimeout(resolve, 10_000))
  }
  expect(trustedAt, 'the certificate was not trusted within 15 minutes').toBeGreaterThan(0)

  // Z1-5: the OS images are read live from titan-incus, through the trust Z1-4 waited for.
  const images = JSON.parse(await expectCode(await request.get(`${API}/v1/os-images`), 200))
  expect(images.length, 'titan-incus lists no VM image').toBeGreaterThan(0)
  log(`Z1-5 os images ${images.length}`)

  // Z1-6: sync every template into the cluster, then wait for each to settle.
  await signInAdmin()
  await expectCode(await request.post(`${API}/v1/admin/templates/sync`, { headers: admin }), 202)
  log('Z1-6 templates/sync 202')

  type ClusterRow = { clusterId: string, currentExistence: string, transition: string | null, requestFailureReason: string | null, externalTemplateId: string | null }
  type Template = { name: string, os: string, clusters: ClusterRow[] }
  let settled: Template[] = []
  const syncStart = Date.now()
  while (Date.now() - syncStart < 25 * 60_000) {
    const res = await request.get(`${API}/v1/admin/templates`, { headers: admin })
    if (res.status() === 401) {
      await signInAdmin()
      continue
    }
    const templates: Template[] = JSON.parse(await expectCode(res, 200))
    const waiting = templates.filter((t) => {
      const row = t.clusters.find((z) => z.clusterId === CLUSTER)
      return row === undefined || row.transition !== null
    })
    if (waiting.length === 0) {
      settled = templates
      break
    }
    await new Promise((resolve) => setTimeout(resolve, 20_000))
  }
  expect(settled.length, `templates did not settle in cluster ${CLUSTER} within 25 minutes`).toBeGreaterThan(0)
  log(`Z1-6 settled after ${Math.round((Date.now() - syncStart) / 1000)}s`)
  for (const t of settled) {
    const row = t.clusters.find((z) => z.clusterId === CLUSTER)!
    log(`Z1-7 ${t.name} os=${t.os} existence=${row.currentExistence} external=${row.externalTemplateId} failure=${JSON.stringify(row.requestFailureReason)}`)
  }
  await signInAdmin('z1-admin-after-sync.png')
})
