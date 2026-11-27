// The sample function of runtimes-verify.sh for the nodejs runtime. The three samples (python, node, go) answer alike.
import fs from 'node:fs';
import os from 'node:os';

function canWrite(file) {
  try {
    fs.writeFileSync(file, '');
    return 'ok';
  } catch {
    return 'denied';
  }
}

export async function handler(event, context) {
  if (event.trigger === 'cron') {
    console.log('CRON-EVENT ' + JSON.stringify(event));
    if (process.env.SAMPLE_CRON === 'fail') throw new Error('sample cron failure');
    return undefined;
  }
  if (event.path === '/fail') throw new Error('sample failure');
  const body = `hello node kernel=${os.release()} uid=${process.getuid()} fnwrite=${canWrite('/function/x')} tmpwrite=${canWrite('/tmp/x')} path=${event.path} fn=${context.functionId} version=${context.versionId} left=${context.getRemainingTimeInMillis()}`;
  return { statusCode: 201, headers: { 'x-runtime': 'node' }, body };
}
