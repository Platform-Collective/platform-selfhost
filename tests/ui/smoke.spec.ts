// Browser smoke test for a running self-hosted deployment.
//
// Uses the user and workspace created by tests/smoke.sh (tests/.smoke-state),
// logs in through the real login page, opens the workspace and checks that an
// issue can be created and is still there after a reload.
//
// SMOKE_MODE=verify only checks that the issue created by an earlier run (saved
// in tests/.smoke-ui-state) is still there, e.g. after an upgrade.

import { expect, test, type Page } from '@playwright/test'
import { existsSync, readFileSync, writeFileSync } from 'fs'
import path from 'path'

const root = path.join(__dirname, '..')
const stateFile = path.join(root, '.smoke-state')
const uiStateFile = path.join(root, '.smoke-ui-state')

function readState (file: string): Record<string, string> {
  if (!existsSync(file)) throw new Error(`${file} not found, run tests/smoke.sh first`)
  const state: Record<string, string> = {}
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.*)$/)
    // values are written with bash printf %q; the ones we use here have no special chars
    if (m != null) state[m[1]] = m[2].replace(/\\(.)/g, '$1')
  }
  return state
}

const state = readState(stateFile)
const verify = process.env.SMOKE_MODE === 'verify'

async function login (page: Page): Promise<void> {
  await page.goto('/login/login')
  // depending on the configuration the login page may start with an OTP form
  const withPassword = page.locator('a', { hasText: 'Login with password' })
  const password = page.locator('input[name=current-password]')
  await expect(withPassword.or(password).first()).toBeVisible()
  if (await withPassword.isVisible()) await withPassword.click()

  await page.locator('input[name=email]').fill(state.SMOKE_EMAIL)
  await password.fill(state.SMOKE_PASSWORD)
  await page.locator('button', { hasText: 'Log In' }).click()
}

async function openTracker (page: Page): Promise<void> {
  const tracker = page.locator('button[id$="TrackerApplication"]')
  const workspaceCard = page.locator('div[class*="workspace"]').first()
  // with a single workspace the app may skip the selection page
  await expect(tracker.or(workspaceCard).first()).toBeVisible({ timeout: 60_000 })
  if (!(await tracker.isVisible())) await workspaceCard.click()
  await tracker.click()
  await page.locator('a[href$="all-issues"]').click()
}

test('log in, open workspace, create an issue', async ({ page }) => {
  await login(page)
  await openTracker(page)

  let title: string
  if (verify) {
    title = readState(uiStateFile).SMOKE_ISSUE_TITLE
  } else {
    title = `Smoke issue ${Date.now()}`
    await page.locator('button > div', { hasText: 'New issue' }).click()
    await page.locator('form[id="tracker:string:NewIssue"] input[type="text"]').fill(title)
    await page.locator('button > span', { hasText: 'Create issue' }).click()
    await expect(page.locator('a', { hasText: title })).toBeVisible()
    writeFileSync(uiStateFile, `SMOKE_ISSUE_TITLE=${title}\n`)
  }

  // the issue must come back from the server, not from local state
  await page.reload()
  await expect(page.locator('a', { hasText: title })).toBeVisible({ timeout: 60_000 })
})
