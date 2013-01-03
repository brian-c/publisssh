require 'colors'
path = require 'path'
fs = require 'fs'
{readdirSyncRecursive} = require 'wrench'
awssum = require 'awssum'
async = require 'async'

amazon = awssum.load 'amazon/amazon'
{S3} = awssum.load 'amazon/s3'

defaultGzips = ['.css', '.js']

DEFAULT_CONTENT_TYPE = 'text/plain'
defaultContentTypes =
  '.js': 'text/javascript'
  '.html': 'text/plain'
  '.css': 'text/css'

class Publisher
  local: ''
  bucket: ''
  prefix: ''
  options: null

  gzip: null
  contentTypes: null

  s3: null

  progress = 0
  total = 0

  constructor: (params = {}) ->
    @[property] = value for own property, value of params when property of @
    @gzip = @options.gzip || defaultGzips
    @contentTypes = @options.contentTypes || defaultContentTypes

    @s3 ?= new S3
      accessKeyId: @options.key || process.env.AMAZON_ACCESS_KEY_ID
      secretAccessKey: @options.secret || process.env.AMAZON_SECRET_ACCESS_KEY
      region: amazon[@options.region || 'US_EAST_1']

  publish: ->
    cwd = process.cwd()

    localFiles = {}
    for file in readdirSyncRecursive @local
      localFiles[file] = new Date (fs.statSync path.resolve @local, file).mtime

    @list (error, remoteFiles) =>
      throw new Error "Couldn't list files in bucket #{@bucket}." if error?

      toAdd = []
      toUpdate = []
      toSkip = []
      toRemove = []

      for file, modified of localFiles
        remoteFile = remoteFiles[file]

        if file of remoteFiles
          if modified > remoteFiles[file] or @options.force
            toUpdate.push file
          else
            toSkip.push file
        else
          toAdd.push file

      if @options.cleanup then for file of remoteFiles
        toRemove.push file unless file of localFiles

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

      # console.log {toAdd, toUpdate, toSkip, toRemove}

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

    content = if extension in @gzip
      'TODO: GZIP'
    else
      fs.readFileSync path.resolve @local, file

    contentType = @contentTypes[extension] || DEFAULT_CONTENT_TYPE

    if @options.simulate
      callback()
    else
      @s3.PutObject
        BucketName: @bucket
        ObjectName: path.join @prefix, file
        ContentLength: content.length
        ContentType: contentType
        ContentEncoding: if extension in @gzip then 'gzip'
        Body: content
        Acl: 'public-read'
        callback

  add: (file, callback) =>
    @progress += 1
    console.log "#{'+'.green} #{file} (#{@progress}/#{@total})"
    @upload arguments...

  update: (file, callback) =>
    @progress += 1
    console.log "#{'Δ'.green} #{file} (#{@progress}/#{@total})"
    @upload arguments...

  remove: (file, callback) =>
    @progress += 1
    console.log "#{'×'.red} #{file} (#{@progress}/#{@total})"

    if @options.simulate
      callback()
    else
      @s3.DeleteObject
        BucketName: @bucket
        ObjectName: path.join @prefix, file
        callback

  onFinished: (errors) =>
    if errors.length is 0
      console.log 'Finished with no errors.'.green
    else
      errorLog = "publisssh-error-log.txt"
      console.error "Finished with #{errors.length} errors.".red
      # TODO: console.error "Logging errors to #{errorLog}.".red

module.exports = Publisher
