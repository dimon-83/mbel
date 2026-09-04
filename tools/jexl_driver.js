#!/usr/bin/env node
/*
 * Stage-3 differential harness: JS side.
 * Reads one Jexl expression per line from the file given as argv[2];
 * evaluates each with the real Jexl (evalSync); prints one canonical
 * line per expression — the value serialized by canon(), or
 * {"$error":true} when evaluation throws.
 *
 * canon() must byte-match cmd/main's canon() on the MoonBit side.
 */
const fs = require('fs')
const JexlLib = require(process.env.JEXL_LIB || '/Users/dexter/workspace/Jexl/lib/Jexl')

function canon(v) {
  if (v === undefined) return '{"$undef":true}'
  if (v === null) return 'null'
  if (typeof v === 'number') {
    if (v !== v) return '{"$nan":true}'
    if (v === Infinity) return '{"$inf":true}'
    if (v === -Infinity) return '{"$ninf":true}'
    return String(v)
  }
  if (typeof v === 'string') return JSON.stringify(v)
  if (typeof v === 'boolean') return String(v)
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']'
  if (typeof v === 'object') {
    const keys = Object.keys(v)
    return '{' + keys.map((k) => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}'
  }
  return '{"$unk":true}'
}

function main() {
  const file = process.argv[2]
  if (!file) {
    console.error('usage: node jexl_driver.js <corpus.txt>')
    process.exit(1)
  }
  const jexl = new JexlLib.Jexl()
  jexl.addTransform('dbl', (v) => v * 2)
  jexl.addTransform('first', (v) => (Array.isArray(v) ? v[0] : undefined))
  jexl.addTransform('concatWith', (v, a) => v + a)
  const lines = fs.readFileSync(file, 'utf8').split('\n')
  for (const line of lines) {
    if (line === '') continue
    // expr<TAB>{json} lines carry their own context (JSON.parse).
    const tab = line.indexOf('\t')
    let expr = line
    let ctx = {}
    if (tab >= 0 && line[tab + 1] === '{') {
      expr = line.slice(0, tab)
      ctx = JSON.parse(line.slice(tab + 1))
    }
    try {
      console.log(canon(jexl.evalSync(expr, ctx)))
    } catch (e) {
      console.log('{"$error":true}')
    }
  }
}

main()
