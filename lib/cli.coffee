optimist = require 'optimist'
pkg = require '../package'
path = require 'path'
publish = require './publish'

LEADING_OR_TRAILING_SLASH = /^[/]|[/]$/g

flags = optimist.usage('''
  Usage:
    publisssh ./local bucket/destination -dr
''').options({
  k: alias: 'key', description: 'AWS access key ID'
  s: alias: 'secret', description: 'AWS secret access key'

  r: alias: 'remove', description: 'Delete remote files that don\'t exist locally'
  i: alias: 'ignore', description: 'Ignore files whose names contain this string'
  d: alias: 'dry-run', description: 'Don\'t actually change anything remotely'

  q: alias: 'quiet', description: 'Don\'t log anything'
  V: alias: 'verbose', description: 'Log extra debugging information'

  h: alias: 'help', description: 'Show these flags'
  v: alias: 'version', description: 'Show the version number'
}).argv

if flags.help or flags._.length is 0
  optimist.showHelp()

else if flags.version
  console.log pkg.version

else
  {_: [[local]..., remote]} = flags
  local ?= process.cwd()

  [bucket, prefixes...] = remote.split path.sep
  prefix = prefixes.join path.sep
  bucket = bucket.replace LEADING_OR_TRAILING_SLASH, ''
  prefix = prefix.replace LEADING_OR_TRAILING_SLASH, ''

  options = {}
  for flag, value of flags when flag.length > 1 and flag.charAt(0).match /[a-z]/i
    optionName = flag.replace /-([a-z])/g, (match, char) ->
      char.toUpperCase()
    options[optionName] = value

  publish local, bucket, prefix, options
