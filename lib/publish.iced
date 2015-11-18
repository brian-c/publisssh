chalk = require 'chalk'
path = require 'path'
AWS = require 'aws-sdk'
fs = require 'fs'
wrench = require 'wrench'
zlib = require 'zlib'
crypto = require 'crypto'
mime = require 'mime'

class Publisher
  s3: null
  key: process.env.AMAZON_ACCESS_KEY_ID
  secret: process.env.AMAZON_SECRET_ACCESS_KEY

  remove: false

  ignore: [
    /^[.]/
  ]

  zip: [
    /[.]html$/
    /[.]css$/
    /[.]js$/
    /[.][c|t]sv$/
  ]

  cacheFor: 24 * 60 * 60 * 1000

  dontCache: [
    /[.]html$/
  ]

  quiet: false
  verbose: false
  dryRun: false

  delay: 3 * 1000

  log: ->
    if @verbose
      console.log chalk.gray (new Date()).toLocaleTimeString(), arguments...

  info: (args...) ->
    unless @quiet
      if typeof args[args.length - 1] is 'boolean'
        suppressLineBreak = args.pop()

      unless suppressLineBreak
        args.push '\n'

      process.stdout.write args.join ' '

  publish: (local, bucket, prefix, options = {}) ->
    for own key, value of options
      @[key] = value

    @info """
      Local: .#{path.sep}#{path.relative process.cwd(), local}
      Bucket: #{bucket}
      Prefix: #{prefix || '(root)'}
    """

    @log 'Options', JSON.stringify this

    @log 'Setting up S3 connection'
    @s3 = new AWS.S3
      accessKeyId: @key
      secretAccessKey: @secret

    @log 'Making sure local source is a directory'
    await fs.stat local, defer error, localStat
    throw error if error?
    if localStat.isDirectory()
      @publishDirectory local, bucket, prefix
    else
      throw new Error 'Publisssh currently only works on directories.'

  publishDirectory: (local, bucket, prefix) ->
    @log 'Publishing', path.resolve local

    await @getRemoteFiles bucket, prefix, defer remoteFiles
    await @getLocalFiles local, defer localFiles
    await @sortFiles local, localFiles, remoteFiles, defer add, replace, skip, remove
    await @printThePlan add, replace, skip, remove, defer()

    i = 0
    total = add.length + replace.length + remove.length

    for name in add
      i += 1
      @info chalk.gray("#{i}/#{total} "), true
      await @addFile bucket, prefix, name, localFiles[name], defer error
      throw error if error?

    for name in replace
      i += 1
      @info chalk.gray("#{i}/#{total} "), true
      await @replaceFile bucket, prefix, name, localFiles[name], defer error
      throw error if error?

    for name in remove
      i += 1
      @info chalk.gray("#{i}/#{total} "), true
      await @removeFile bucket, prefix, name, defer error
      throw error if error?

    @info chalk.green "Finished in #{process.uptime()} seconds"

    if @dryRun
      @info chalk.yellow 'This was a dry run. No changes have been made remotely.'

  getRemoteFiles: (bucket, prefix, callback, files = {}, marker) ->
    @log 'Getting remote files', bucket, prefix, Object.keys(files).length

    @s3.listObjects
      Bucket: bucket
      Prefix: prefix
      Marker: marker if marker?
      (error, {Contents, IsTruncated}) =>
        throw error if error?
        for {Key, ETag} in Contents
          name = Key[prefix.length + 1...]
          if @shouldIgnore name
            @log 'Ignoring', name
          else
            hash = ETag[1...-1]
            @log 'Remote', name, hash
            files[name] = {hash}
          marker = Key
        if IsTruncated
          @log 'Remote file list is truncated'
          @getRemoteFiles bucket, prefix, callback, files, marker
        else
          callback files

  getLocalFiles: (local, callback) ->
    @log 'Getting local files', local

    allFiles = []
    wrench.readdirRecursive local, (error, names) =>
      throw error if error?
      if names?
        allFiles.push names...
      else
        files = {}
        for name in allFiles
          if @shouldIgnore name
            @log 'Ignoring', name
          else
            await fs.stat path.join(local, name), defer error, fileStat
            throw error if error?
            if fileStat.isDirectory()
              @log 'Skipping directory', name
            else
              @log 'Local', name
              files[name] = {}
              await fs.readFile path.resolve(local, name), defer error, files[name].content
              throw error if error?
              if @shouldZip name
                @log 'Zipping content'
                await zlib.gzip files[name].content, defer error, files[name].content
                throw error if error?
                files[name].gzip = true
        callback files

  sortFiles: (local, localFiles, remoteFiles, callback) ->
    @log 'Sorting files'

    add = []
    replace = []
    skip = []
    remove = []

    for localFileName, localFile of localFiles
      @log 'Sorting local file', localFileName
      if localFileName of remoteFiles
        @log 'Present remotely, will check hash'
        remoteFile = remoteFiles[localFileName]
        localFile.hash = crypto.createHash('md5').update(localFile.content).digest 'hex'
        if localFile.hash is remoteFile.hash
          @log 'Hash matches, will skip'
          skip.push localFileName
        else
          @log 'Hash doesn\'t match, will replace'
          replace.push localFileName
      else
        @log 'Not present remotely, will add'
        add.push localFileName

    if @remove
      for remoteFileName of remoteFiles
        @log 'Sorting remote file', remoteFileName
        if remoteFileName not of localFiles
          @log 'Not present locally, will remove'
          remove.push remoteFileName

    callback add, replace, skip, remove

  printThePlan: (add, replace, skip, remove, callback) ->
    @log 'Printing the plan'
    thePlan = []
    thePlan.push "adding #{add.length}" unless add.length is 0
    thePlan.push "replacing #{replace.length}" unless replace.length is 0
    thePlan.push "skipping #{skip.length}" unless skip.length is 0
    thePlan.push "removing #{remove.length}" unless remove.length is 0
    thePlan = thePlan.join ', '
    thePlan = thePlan.charAt(0).toUpperCase() + thePlan[1...]

    @info thePlan, true
    setTimeout (=> @info '.', true), (@delay / 4) * 1
    setTimeout (=> @info '.', true), (@delay / 4) * 2
    setTimeout (=> @info '.', false), (@delay / 4) * 3
    setTimeout callback, @delay

  addFile: (bucket, prefix, name, file, callback) ->
    @info chalk.green('+'), name
    @upload arguments...

  replaceFile: (bucket, prefix, name, file, callback) ->
    @info chalk.yellow('∆'), name
    @upload arguments...

  upload: (bucket, prefix, name, {content, gzip}, callback) ->
    remoteName = path.join prefix, name
    mimeType = mime.lookup name
    @log 'Uploading', remoteName, mimeType

    if @dryRun
      setTimeout callback, 50
    else
      @s3.putObject
        Bucket: bucket
        Key: remoteName
        Body: content
        ContentLength: content.length
        ContentType: mimeType
        ContentEncoding: if gzip then 'gzip' else ''
        CacheControl: if @shouldNotCache(name)
          'no-cache, must-revalidate'
        else
          "max-age = #{@cacheFor / 1000}"
        ACL: 'public-read'
        callback

  removeFile: (bucket, prefix, name, callback) ->
    remoteName = path.join prefix, name
    @log 'Removing', remoteName

    @info chalk.red('×'), name
    if @dryRun
      setTimeout callback, 50
    else
      @s3.deleteObject
        Bucket: bucket
        Key: remoteName
        callback

  shouldIgnore: (name) ->
    @log 'Testing should-ignore', name
    [].concat(@ignore).some (pattern) ->
      name.match pattern

  shouldZip: (name) ->
    @log 'Testing should-zip', name
    [].concat(@zip).some (pattern) ->
      name.match pattern

  shouldNotCache: (name) ->
    @log 'Testing should-not-cache', name
    [].concat(@dontCache).some (pattern) ->
      name.match pattern

publish = ->
  (new Publisher).publish arguments...

module.exports = publish
module.exports.Publisher = Publisher
