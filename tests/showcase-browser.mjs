import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';
import { startShowcaseServer } from '../tools/serve_showcase.mjs';

const { server, url } = await startShowcaseServer();
let browser;
try {
  browser = await chromium.launch({ channel: process.env.PEONY_BROWSER_CHANNEL ?? 'chrome', headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const pageErrors = [];
  page.on('pageerror', error => pageErrors.push(error.message));
  await page.addInitScript(() => {
    const NativeWorker = window.Worker;
    window.__peonyWorkerCount = 0;
    window.Worker = new Proxy(NativeWorker, {
      construct(target, args) {
        window.__peonyWorkerCount += 1;
        return Reflect.construct(target, args);
      },
    });
    WebAssembly.instantiate = () => { throw new Error('WASM instantiated on page main thread'); };
    WebAssembly.compile = () => { throw new Error('WASM compiled on page main thread'); };
  });
  await page.goto(url);
  await page.waitForFunction(() => document.querySelector('#runtime-status')?.textContent === 'Ready', null, { timeout: 15_000 });
  assert.equal(await page.evaluate(() => window.__peonyWorkerCount), 1);

  await page.locator('#editor').fill('print("Hello from Peony")\n');
  await page.locator('#run-button').click();
  await page.waitForFunction(() => document.querySelector('#run-detail')?.textContent === 'Completed');
  assert.match(await page.locator('#output').textContent(), /Hello from Peony/);

  for (const [example, expected] of [
    ['hello', 'Try 3'],
    ['words', 'one: 1'],
    ['files', 'Peony writes this file in its Worker.'],
    ['patterns', 'hello@example.com'],
  ]) {
    await page.locator('#example-select').selectOption(example);
    await page.locator('#run-button').click();
    await page.waitForFunction(() => ['Completed', 'Check the error below'].includes(document.querySelector('#run-detail')?.textContent));
    assert.equal(await page.locator('#run-detail').textContent(), 'Completed', `${example} example should run`);
    assert.ok((await page.locator('#output').textContent()).includes(expected), `${example} example output`);
  }

  await page.locator('#editor').fill('name = input("Name? ")\nprint("Hello", name)\n');
  await page.locator('#run-button').click();
  await page.locator('#input-form').waitFor({ state: 'visible' });
  await page.locator('#input-value').fill('Ada');
  await page.locator('#input-form button').click();
  await page.waitForFunction(() => document.querySelector('#run-detail')?.textContent === 'Completed');
  assert.match(await page.locator('#output').textContent(), /Hello Ada/);

  await page.locator('#editor').fill('input("Waiting for an answer: ")\nprint("late")\n');
  await page.locator('#run-button').click();
  await page.locator('#input-form').waitFor({ state: 'visible' });
  await page.locator('#stop-button').click();
  await page.waitForFunction(() => document.querySelector('#run-detail')?.textContent === 'Stopped', null, { timeout: 5_000 });
  await page.locator('#input-form').waitFor({ state: 'hidden' });
  assert.doesNotMatch(await page.locator('#output').textContent(), /late/);

  await page.locator('#editor').fill('print(2 + 2)\n');
  await page.locator('#editor').press('Control+Enter');
  await page.waitForFunction(() => document.querySelector('#run-detail')?.textContent === 'Completed');
  assert.match(await page.locator('#output').textContent(), /4/);

  await page.locator('#editor').fill('print(1 / 0)\n');
  await page.locator('#run-button').click();
  await page.locator('#error-card').waitFor({ state: 'visible' });
  assert.match(await page.locator('#error-message').textContent(), /ZeroDivisionError/);
  const line = page.locator('#error-location');
  await line.waitFor({ state: 'visible' });
  await line.click();
  assert.equal(await page.locator('#editor').evaluate(element => element.selectionStart), 0);

  await page.locator('#editor').fill('match 1:\n    case [x]:\n        print(x)\n');
  await page.locator('#run-button').click();
  await page.locator('#error-card').waitFor({ state: 'visible' });
  assert.match(await page.locator('#error-message').textContent(), /sequence pattern matching is not supported/);
  await page.locator('#error-location').waitFor({ state: 'visible', timeout: 5_000 });
  assert.match(await page.locator('#error-location').textContent(), /main\.py:2/);

  await page.locator('#editor').fill('print("ready", flush=True)\nwhile True:\n    pass\n');
  await page.locator('#run-button').click();
  await page.waitForFunction(() => document.querySelector('#output')?.textContent.includes('ready'));
  const stopStart = Date.now();
  await page.locator('#stop-button').click();
  await page.waitForFunction(() => document.querySelector('#run-detail')?.textContent === 'Stopped', null, { timeout: 5_000 });
  assert.ok(Date.now() - stopStart < 5_000, 'page should remain responsive during Python execution');

  await mkdir(new URL('../.zig-cache/showcase/', import.meta.url), { recursive: true });
  await page.screenshot({ path: fileURLToPath(new URL('../.zig-cache/showcase/desktop.png', import.meta.url)), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  const editorBox = await page.locator('.editor-panel').boundingBox();
  const outputBox = await page.locator('.output-panel').boundingBox();
  assert.ok(editorBox && outputBox && outputBox.y >= editorBox.y + editorBox.height - 1);
  await page.screenshot({ path: fileURLToPath(new URL('../.zig-cache/showcase/mobile.png', import.meta.url)), fullPage: true });
  assert.deepEqual(pageErrors, []);
  process.stdout.write('Peony showcase: Worker-only run, input, errors, stop, and narrow layout passed.\n');
} finally {
  await browser?.close();
  await new Promise(resolve => server.close(resolve));
}
