import { createFsHost } from '../web/fs-host.mjs';

export async function instantiatePeony(bytes) {
  const filesystem = createFsHost();
  const result = await WebAssembly.instantiate(bytes, filesystem.imports);
  filesystem.bind(result.instance.exports);
  return result;
}

export async function instantiatePeonyStreaming(response) {
  const filesystem = createFsHost();
  const result = await WebAssembly.instantiateStreaming(response, filesystem.imports);
  filesystem.bind(result.instance.exports);
  return result;
}
