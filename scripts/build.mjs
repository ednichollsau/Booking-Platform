import {mkdir,copyFile,readdir} from 'node:fs/promises'
await mkdir('dist',{recursive:true})
for(const name of await readdir('.')) if(/\.(html|otf)$/.test(name) || name==='clinic-time.mjs') await copyFile(name,'dist/'+name)
