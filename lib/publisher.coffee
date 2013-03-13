require 'colors'
path = require 'path'
fs = require 'fs'
{readdirSyncRecursive} = require 'wrench'
awssum = require 'awssum'
async = require 'async'
mime = require 'mime'

amazon = awssum.load 'amazon/amazon'
{S3} = awssum.load 'amazon/s3'

defaultGzips = ['.css', '.js']

err = (message) ->
  console.log message.red
  process.exit 1

isDir = (path) ->
  try return (fs.statSync path).isDirectory()
  false

class Publisher
  local: ''
  bucket: ''
  prefix: ''
  options: null

  gzip: null

  s3: null

  progress = 0
  total = 0

  constructor: (params = {}) ->
    @[property] = value for own property, value of params when property of @

    @gzip = @options.gzip || defaultGzips

    @s3 ?= new S3
      accessKeyId: @options.key || process.env.AMAZON_ACCESS_KEY_ID
      secretAccessKey: @options.secret || process.env.AMAZON_SECRET_ACCESS_KEY
      region: amazon[@options.region || 'US_EAST_1']

  publish: ->
    console.log """
      Local:  #{@local}
      Bucket: #{@bucket}
      Prefix: #{@prefix || '(none)'}
    """

    err "Couldn't find local #{@local}" unless isDir @local

    cwd = process.cwd()

    localFiles = {}

    for file in readdirSyncRecursive @local
      continue if file.match @options.ignore || null
      localFiles[file] = new Date (fs.statSync path.resolve @local, file).mtime

    @list (error, remoteFiles) =>
      err "Couldn't list files in bucket #{@bucket}." if error?

      toAdd = []
      toUpdate = []
      toSkip = []
      toRemove = []

      for file, modified of localFiles
        continue if isDir path.resolve @local, file
        if "#{@prefix}/#{file}" of remoteFiles
          if modified > remoteFiles[file] or @options.force
            toUpdate.push file
          else
            toSkip.push file
        else
          toAdd.push file

      if @options.remove then for file of remoteFiles
        continue if file.match @options.ignore
        continue if fs.existsSync path.resolve @local, file[@prefix.length + 1...] # TODO: Clean up
        toRemove.push file unless file[@prefix.length + 1...] of localFiles

      todo = []
      todo.push "adding #{toAdd.length}" unless toAdd.length is 0
      todo.push "updating #{toUpdate.length}" unless toUpdate.length is 0
      todo.push "skipping #{toSkip.length}" unless toSkip.length is 0
      todo.push "removing #{toRemove.length}" unless toRemove.length is 0
      todo = "#{todo.join ', '}."
      todo = todo.charAt(0).toUpperCase() + todo[1...]
      console.log todo

      @progress = 0
      @total = ([].concat toAdd, toUpdate, toRemove).length
      errors = []

      async.forEachSeries toAdd, @add, (error) =>
        errors.push error if error?

        async.forEachSeries toUpdate, @update, (error) =>
          errors.push error if error?

          async.forEachSeries toRemove, @remove, (error) =>
            errors.push error if error?

            @onFinished errors

  list: (callback) ->
    @s3.ListObjects BucketName: @bucket, Prefix: @prefix, (error, data) =>
      callback error if error?
      objects = data.Body.ListBucketResult.Contents
      return callback null, [] unless objects?
      objects = [objects] unless objects instanceof Array

      files = {}
      files[o.Key] = new Date o.LastModified for o in objects
      callback error, files

  upload: (file, callback) ->
    extension = path.extname file

    if extension in @gzip
      # TODO: GZIP
      content = fs.readFileSync path.resolve @local, file
      contentType = mime.lookup file
    else
      content = fs.readFileSync path.resolve @local, file
      contentType = mime.lookup file

    if @options['dry-run']
      callback()
    else
      @s3.PutObject
        BucketName: @bucket
        ObjectName: path.join @prefix, file
        ContentLength: content.length
        ContentType: contentType
        # ContentEncoding: if extension in @gzip then 'gzip'
        Body: content
        Acl: 'public-read'
        callback

  add: (file, callback) =>
    @progress += 1
    console.log "#{'+'.green} #{path.resolve process.cwd(), file} (#{@progress}/#{@total})"
    @upload arguments...

  update: (file, callback) =>
    @progress += 1
    console.log "#{'Δ'.yellow} #{path.resolve process.cwd(), file} (#{@progress}/#{@total})"
    @upload arguments...

  remove: (file, callback) =>
    @progress += 1
    console.log "#{'×'.red} #{file} (#{@progress}/#{@total})"

    if @options['dry-run']
      callback()
    else
      @s3.DeleteObject
        BucketName: @bucket
        ObjectName: file
        callback

  onFinished: (errors) =>
    if errors.length is 0
      console.log 'Finished with no errors.'.green
    else
      errorLog = "publisssh-error-log.txt"
      console.error "Finished with #{errors.length} errors.".red
      TODO: console.error "Logging errors to #{errorLog}.".red
      fs.writeFileSync errorLog, "#{errors.join '\n'}\n"

module.exports = Publisher
