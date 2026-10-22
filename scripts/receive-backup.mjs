// Transport helper: newline-delimited base64 on a non-echoing terminal, terminated by END.
import {spawnSync} from 'node:child_process'
let input=''
process.stdin.setEncoding('utf8')
process.stdin.on('data',chunk=>{
 input+=chunk
 if(!input.endsWith('\nEND\n')) return
 const content=Buffer.from(input.slice(0,-5).replace(/\s/g,''),'base64')
 const result=spawnSync(process.execPath,[new URL('./encrypt-backup.mjs',import.meta.url).pathname,process.argv[2]],{input:content,encoding:'utf8'})
 content.fill(0);input=''
 process.stdout.write(result.stdout || '')
 if(result.status!==0) process.stderr.write(result.stderr || 'Backup encryption failed')
 process.exit(result.status || 0)
})
