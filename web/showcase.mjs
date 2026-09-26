import { Peony } from './peony.mjs';

const examples = {
  hello: `print("Hello, Peony!")\nfor number in range(1, 4):\n    print(f"Try {number}")\n`,
  words: `from collections import Counter\n\nwords = "one small runtime can go a long way".split()\nfor word, count in Counter(words).most_common():\n    print(f"{word}: {count}")\n`,
  files: `from pathlib import Path\n\nnote = Path("/home/note.txt")\nnote.write_text("Peony runs this file in its VFS.\\n")\nprint(note.read_text())\n`,
  input: `name = input("What is your name? ")\nprint(f"Nice to meet you, {name}.")\n`,
  patterns: `import re\n\nmessage = "Contact me at hello@example.com"\nmatch = re.search(r"[\\w.]+@[\\w.]+", message)\nprint(match.group() if match else "No address found")\n`,
};

const editor = document.querySelector('#editor');
const lineNumbers = document.querySelector('#line-numbers');
const output = document.querySelector('#output');
const emptyOutput = document.querySelector('#empty-output');
const errorCard = document.querySelector('#error-card');
const errorMessage = document.querySelector('#error-message');
const errorLocation = document.querySelector('#error-location');
const runButton = document.querySelector('#run-button');
const stopButton = document.querySelector('#stop-button');
const clearButton = document.querySelector('#clear-button');
const exampleSelect = document.querySelector('#example-select');
const status = document.querySelector('#runtime-status');
const detail = document.querySelector('#run-detail');
const inputForm = document.querySelector('#input-form');
const inputLabel = document.querySelector('#input-label');
const inputValue = document.querySelector('#input-value');

let peony;
let session;
let running = false;
let pendingInput = null;

function setStatus(text, state = 'ready') {
  status.textContent = text;
  status.dataset.state = state;
}

function updateLines() {
  const count = editor.value.split('\n').length;
  lineNumbers.textContent = Array.from({ length: count }, (_, index) => index + 1).join('\n');
  lineNumbers.scrollTop = editor.scrollTop;
}

function saveEditor() {
  try { localStorage.setItem('peony:main.py', editor.value); } catch { /* private browsing can disable storage */ }
}

function appendOutput(text) {
  if (text.length === 0) return;
  emptyOutput.hidden = true;
  output.textContent += text;
  output.parentElement.scrollTop = output.parentElement.scrollHeight;
}

function clearOutput() {
  output.textContent = '';
  emptyOutput.hidden = false;
  errorCard.hidden = true;
  errorLocation.hidden = true;
}

function showError(message, frames = []) {
  emptyOutput.hidden = true;
  errorCard.hidden = false;
  errorMessage.textContent = message;
  const frame = frames.at(-1);
  if (frame && Number.isInteger(frame.line) && frame.line > 0) {
    errorLocation.textContent = `Go to ${frame.filename ?? 'main.py'}:${frame.line}`;
    errorLocation.dataset.line = String(frame.line);
    errorLocation.hidden = false;
  } else {
    errorLocation.hidden = true;
  }
}

function hideInput(value = null) {
  if (pendingInput) {
    const resolve = pendingInput;
    pendingInput = null;
    resolve(value);
  }
  inputForm.hidden = true;
  inputValue.value = '';
}

function askInput(prompt) {
  hideInput();
  inputLabel.textContent = prompt || 'Input';
  inputForm.hidden = false;
  inputValue.focus();
  return new Promise(resolve => { pendingInput = resolve; });
}

async function runCurrent() {
  if (!session || running) return;
  hideInput();
  clearOutput();
  running = true;
  runButton.disabled = true;
  stopButton.disabled = false;
  setStatus('Running', 'running');
  detail.textContent = 'main.py';
  try {
    const result = await session.run(editor.value, { filename: '/home/main.py' });
    if (result.status === 'completed') {
      setStatus('Ready');
      detail.textContent = 'Completed';
    } else if (result.status === 'cancelled') {
      setStatus('Ready');
      detail.textContent = 'Stopped';
    } else if (result.status === 'limit') {
      setStatus('Limit reached', 'error');
      detail.textContent = 'Program limit reached';
      showError('This program reached its work limit. Check for a loop that does not finish.');
    } else {
      setStatus('Error', 'error');
      detail.textContent = 'Check the error below';
      showError(result.error?.message ?? 'The program could not finish.', result.frames);
    }
  } catch (error) {
    setStatus('Error', 'error');
    detail.textContent = 'Could not run';
    showError(error instanceof Error ? error.message : String(error));
  } finally {
    hideInput();
    running = false;
    runButton.disabled = !session;
    stopButton.disabled = true;
  }
}

function stopCurrent() {
  if (!running) return;
  setStatus('Stopping', 'running');
  session.cancel();
  hideInput();
}

function goToLine(line) {
  const lines = editor.value.split('\n');
  if (line < 1 || line > lines.length) return;
  let start = 0;
  for (let index = 0; index < line - 1; index += 1) start += lines[index].length + 1;
  editor.focus();
  editor.setSelectionRange(start, start + lines[line - 1].length);
  const lineHeight = parseFloat(getComputedStyle(editor).lineHeight) || 21;
  editor.scrollTop = Math.max(0, (line - 3) * lineHeight);
  updateLines();
}

editor.addEventListener('input', () => { updateLines(); saveEditor(); });
editor.addEventListener('scroll', () => { lineNumbers.scrollTop = editor.scrollTop; });
editor.addEventListener('keydown', event => {
  if (event.key !== 'Tab') return;
  event.preventDefault();
  const start = editor.selectionStart;
  const end = editor.selectionEnd;
  editor.setRangeText('    ', start, end, 'end');
  updateLines();
  saveEditor();
});
document.addEventListener('keydown', event => {
  if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
    event.preventDefault();
    void runCurrent();
  }
  if (event.key === 'Escape' && running) stopCurrent();
});
exampleSelect.addEventListener('change', () => {
  const selected = examples[exampleSelect.value];
  if (selected) {
    editor.value = selected;
    updateLines();
    saveEditor();
    editor.focus();
  }
  exampleSelect.value = '';
});
runButton.addEventListener('click', () => { void runCurrent(); });
stopButton.addEventListener('click', stopCurrent);
clearButton.addEventListener('click', clearOutput);
errorLocation.addEventListener('click', () => goToLine(Number(errorLocation.dataset.line)));
inputForm.addEventListener('submit', event => {
  event.preventDefault();
  const answer = inputValue.value;
  hideInput(answer);
});

try { editor.value = localStorage.getItem('peony:main.py') || examples.hello; }
catch { editor.value = examples.hello; }
updateLines();

try {
  peony = await Peony.load(new URL('../zig-out/peony.wasm', import.meta.url));
  session = peony.createSession({
    stdout: appendOutput,
    stderr: appendOutput,
    input: askInput,
  });
  setStatus('Ready');
  runButton.disabled = false;
} catch (error) {
  setStatus('Unavailable', 'error');
  detail.textContent = 'Could not start Peony';
  showError(error instanceof Error ? error.message : String(error));
}

window.addEventListener('beforeunload', () => { void peony?.terminate(); });
