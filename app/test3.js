const { spawn } = require('child_process');
const child = spawn('gemini', ['-m', 'gemini-3.1-pro-preview', '--output-format', 'stream-json', '--yolo']); // no -i, no -p
child.stdout.on('data', d => process.stdout.write('OUT: ' + d.toString()));
child.stderr.on('data', d => process.stderr.write('ERR: ' + d.toString()));
child.stdin.write('hello\\n');
setTimeout(() => child.stdin.write('what is 1+1?\\n'), 3000);
setTimeout(() => child.stdin.end(), 6000);
