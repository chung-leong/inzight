const { createRequire } = await import('node-zigar/cjs');
const require = createRequire(import.meta.url);
const {
  startServer,
  stopServer,
  addStaticDirectory,
  addDynamicDirectory,
} = require('../lib/server.zigar');

export {
  startServer,
  stopServer,
  addStaticDirectory,
  addDynamicDirectory,
};