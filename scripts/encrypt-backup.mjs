// Input: UTF-8 JSON on stdin. Output: authenticated AES-256-GCM envelope encrypted to a separate RSA recovery key.
import {readFile,writeFile,mkdir} from 'node:fs/promises'
import {randomBytes,createCipheriv,publicEncrypt,constants} from 'node:crypto'
const destination=process.argv[2]
if(!destination) throw new Error('Backup destination required')
const chunks=[]
for await(const chunk of process.stdin) chunks.push(chunk)
const plaintext=Buffer.concat(chunks)
try { JSON.parse(plaintext.toString('utf8')) } catch { console.error('Backup input failed validation'); process.exit(1) }
const key=randomBytes(32),iv=randomBytes(12)
const cipher=createCipheriv('aes-256-gcm',key,iv)
const ciphertext=Buffer.concat([cipher.update(plaintext),cipher.final()])
const publicKey=await readFile(new URL('./backup-public-key.pem',import.meta.url))
const wrapped=publicEncrypt({key:publicKey,padding:constants.RSA_PKCS1_OAEP_PADDING,oaepHash:'sha256'},key)
const envelope={version:1,created_at:new Date().toISOString(),cipher:'AES-256-GCM',key_wrap:'RSA-OAEP-SHA256',key:wrapped.toString('base64'),iv:iv.toString('base64'),tag:cipher.getAuthTag().toString('base64'),data:ciphertext.toString('base64')}
await writeFile(destination,JSON.stringify(envelope),{mode:0o600,flag:'wx'})
key.fill(0);plaintext.fill(0)
console.log('Encrypted backup saved: '+destination)
