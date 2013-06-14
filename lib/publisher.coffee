require 'colors'
path = require 'path'
fs = require 'fs'
wrench = require 'wrench'
AWS = require 'aws-sdk'
async = require 'async'
crypto = require 'crypto'
mime = require 'mime'
zlib = require 'zlib'

CWD = process.cwd()

ERROR_LOG = "publisssh-error-log.txt"

isDir = (path) ->
  try return (fs.statSync path).isDirectory()
  false

class Publisher
  local: ''
  bucket: ''
  prefix: ''
  options: null

  gzip: [
    /\.css$/
    /\.js$/
  ]

  dontCache: [
    /^index\.html$/
  ]

  s3: null

  progress = 0
  total = 0

  constructor: (params = {}) ->
    @[property] = value for own property, value of params when property of @

    AWS.config.update
      accessKeyId: @options.key
      secretAccessKey: @options.secret

    @s3 = new AWS.S3

  log: (message...) ->
    console.log message...

  die: (error) ->
    console.error error.red || error
    process.exit 1

  publish: ->
    @die "Couldn't find local directory: #{path.relative CWD, @local}" unless isDir @local

    @log """
      Local:  #{path.relative CWD, @local}
      Bucket: #{@bucket}
      Prefix: #{@prefix || '(none)'}
    """

    @getFiles()

  getFiles: ->
    localFiles = wrench.readdirSyncRecursive @local

    @s3.listObjects
      Bucket: @bucket
      Prefix: @prefix
      (error, {IsTruncated, Contents: objects}) =>
        @die error if error?

        # TODO: Make another request with "marker" set to the last file.
        @log 'Warning: List of remote files was truncated.'.yellow if IsTruncated

        remoteFiles = {}
        for object in objects
          remoteFiles[object.Key] = object.ETag[1...-1]

        @separateFiles localFiles, remoteFiles

  separateFiles: (localFiles, remoteFiles) ->
    toAdd = []
    toUpdate = []
    toSkip = []
    toRemove = []

    for localFile, i in localFiles
      continue if @options.ignore?.test localFile

      prefixed = path.join (@prefix || ''), localFile
      localFile = path.resolve @local, localFile

      if isDir localFile
        # S3 return directories with a trailing slash.
        localFiles[i] = (path.relative @local, localFile) + path.sep
        continue

      if prefixed of remoteFiles
        md5 = crypto.createHash('md5').update(fs.readFileSync localFile).digest 'hex'
        if md5 is remoteFiles[prefixed]
          toSkip.push localFile
        else
          console.log 'Up', prefixed
          toUpdate.push localFile
      else
        console.log 'Add', prefixed
        toAdd.push localFile

    if @options.remove
      for remoteFile of remoteFiles
        remoteAsLocal = remoteFile[((@prefix.length || -1) + 1)...]
        continue if remoteAsLocal in localFiles
        continue if @options.ignore?.test remoteFile
        console.log {remove: remoteFile}
        toRemove.push remoteFile

    thePlan = []
    thePlan.push "adding #{toAdd.length}" unless toAdd.length is 0
    thePlan.push "updating #{toUpdate.length}" unless toUpdate.length is 0
    thePlan.push "skipping #{toSkip.length}" unless toSkip.length is 0
    thePlan.push "removing #{toRemove.length}" unless toRemove.length is 0
    thePlan = "#{thePlan.join ', '}."
    thePlan = thePlan.charAt(0).toUpperCase() + thePlan[1...]
    @log thePlan

    setTimeout (=> @applyChanges toAdd, toUpdate, toSkip, toRemove), 1000

  applyChanges: (toAdd, toUpdate, toSkip, toRemove) ->
    @progress = 0
    @total = ([].concat toAdd, toUpdate, toRemove).length

    errors = []

    async.forEachSeries toAdd, @add, (error) =>
      errors.push error if error?

      async.forEachSeries toUpdate, @update, (error) =>
        errors.push error if error?

        async.forEachSeries toRemove, @remove, (error) =>
          errors.push error if error?

          @finishUp errors

  add: (file, callback) =>
    @progress += 1
    @log "(#{@progress}/#{@total}) #{'+'.green} #{path.relative CWD, file}"
    @upload file, callback

  update: (file, callback) =>
    @progress += 1
    @log "(#{@progress}/#{@total}) #{'Δ'.yellow} #{path.relative CWD, file}"
    @upload file, callback

  maybeZip: (file, callback) ->
    shouldZip = (true for expression in @gzip when expression.test file).length > 0
    content = fs.readFileSync path.resolve @local, file

    if shouldZip
      zlib.gzip content, (error, content) ->
        callback error, content, true
    else
      callback null, content, false

  upload: (file, callback) ->
    shouldntCache = (true for expression in @dontCache when expression.test file).length > 0

    @maybeZip file, (error, content, isZipped) =>
      if @options['dry-run']
        callback()
      else
        @s3.putObject
          Bucket: @bucket
          Key: path.join @prefix, file
          Body: content
          ContentLength: content.length
          ContentType: mime.lookup file
          ContentEncoding: if isZipped then 'gzip' else ''
          CacheControl: if shouldntCache then 'no-cache, must-revalidate' else ''
          ACL: 'public-read'
          callback

  remove: (file, callback) =>
    @progress += 1
    @log "(#{@progress}/#{@total}) #{'×'.red} #{file}"

    if @options['dry-run']
      callback()
    else
      @s3.deleteObject
        Bucket: @bucket
        Key: file
        callback

  finishUp: (errors) =>
    if errors.length is 0
      @log 'Finished with no errors.'.green
    else
      @log "Finished with #{errors.length} errors.".red
      @log "Logging errors to #{ERROR_LOG}.".red
      fs.writeFileSync ERROR_LOG, "#{JSON.stringify errors}\n"

    @log 'This was a dry run. No changes have been made remotely.' if @options['dry-run']

module.exports = Publisher
