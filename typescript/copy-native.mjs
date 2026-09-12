import { mkdir, copyFile } from 'node:fs/promises';
await mkdir(new URL('./dist/', import.meta.url), { recursive: true });
await copyFile(new URL('./build/Release/synurang_module_host.node', import.meta.url),
  new URL('./dist/synurang_module_host.node', import.meta.url));
