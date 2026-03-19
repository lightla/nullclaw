const { spawn } = require('child_process');
const child = spawn('gemini', ['-m', 'gemini-3.1-pro-preview', '--output-format', 'stream-json', '--yolo']);
child.stdout.on('data', d => console.log('OUT:', d.toString()));
child.stderr.on('data', d => console.error('ERR:', d.toString()));
child.stdin.write('hello\\n');
setTimeout(() => child.stdin.write('what is 1+1?\\n'), 3000);
setTimeout(() => child.stdin.end(), 6000);
