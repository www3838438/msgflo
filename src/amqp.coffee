
amqp = require 'amqplib/callback_api'
debug = require('debug')('msgflo:amqp')

interfaces = require './interfaces'

class Client
  constructor: (@address, @options={}) ->
    @connection = null
    @channel = null
    @options.prefetch = 2 if not @options.prefetch?

  ## Broker connection management
  connect: (callback) ->
    debug 'connect', @address
    amqp.connect @address, (err, conn) =>
      debug 'connected', err
      return callback err if err
      @connection = conn
      conn.createChannel (err, ch) =>
        debug 'channel created', err
        return callback err if err
        @channel = ch
        debug 'setting prefetch', @options.prefetch
        @channel.prefetch @options.prefetch
        @channel.on 'close', () ->
          debug 'channel closed'
        @channel.on 'error', (err) ->
          throw err if err
        return callback null

  disconnect: (callback) ->
    debug 'disconnect'
    @channel.close (err) =>
      debug 'close', err
      return callback err

  ## Manipulating queues
  createQueue: (type, queueName, callback) ->
    debug 'create queue', type, queueName
    options = {}
    if type == 'inqueue'
      @channel.assertQueue queueName, options, callback
    else
      exchangeName = queueName
      @channel.assertExchange exchangeName, 'fanout', options, (err) =>
        return callback err if err
        # HACK: to make inqueue==outqueue work:
        @channel.assertQueue queueName, options, (err) =>
          @channel.bindQueue exchangeName, queueName, '', {}, callback

  removeQueue: (type, queueName, callback) ->
    debug 'remove queue', type, queueName
    if type == 'inqueue'
      @channel.deleteQueue queueName, {}, callback
    else
      exchangeName = queueName
      @channel.deleteExchange exchangeName, {}, (err) =>
        return callback err if err
        @channel.deleteQueue queueName, {}, callback

  ## Sending/Receiving messages
  sendToQueue: (exchangeName, message, callback) ->
    # queue must exists
    debug 'send', exchangeName
    data = new Buffer JSON.stringify message
    routingKey = '' # ignored for fan-out exchanges
    @channel.publish exchangeName, routingKey, data, (err) ->
      return callback err if err
    return callback null

  subscribeToQueue: (queueName, handler, callback) ->
    debug 'subscribe', queueName
    # queue must exists
    deserialize = (message) =>
      debug 'receive on queue', queueName, message.fields.deliveryTag
      data = null
      try
        data = JSON.parse message.content.toString()
      catch e
        debug 'JSON exception:', e
      out =
        amqp: message
        data: data
      return handler out
    @channel.consume queueName, deserialize
    debug 'subscribed', queueName
    return callback null

  ## ACK/NACK messages
  ackMessage: (message) ->
    fields = message.amqp.fields
    debug 'ACK', fields.routingKey, fields.deliveryTag
    # NOTE: server will only give us new message after this
    @channel.ack message.amqp, false
  nackMessage: (message) ->
    fields = message.amqp.fields
    debug 'NACK', fields.routingKey, fields.deliveryTag
    @channel.nack message.amqp, false

  # Participant registration
  registerParticipant: (part, callback) ->
    msg =
      protocol: 'discovery'
      command: 'participant'
      payload: part
    @channel.assertQueue 'fbp'
    data = new Buffer JSON.stringify msg
    @channel.sendToQueue 'fbp', data
    return callback null

class MessageBroker extends Client
  constructor: (address, options) ->
    super address, options

  addBinding: (binding, callback) ->
    # TODO: support roundrobin type
    debug 'Broker.addBinding', binding
    @channel.bindQueue binding.tgt, binding.src, '', {}, callback
  removeBinding: (binding, callback) ->
    # FIXME: implement
    return callback null
  listBindings: (from, callback) ->
    return callback null, []
    
  # Participant registration
  subscribeParticipantChange: (handler) ->
    deserialize = (message) =>
      debug 'receive on fbp', message.fields.deliveryTag
      data = null
      try
        data = JSON.parse message.content.toString()
      catch e
        debug 'JSON exception:', e
      out =
        amqp: message
        data: data
      return handler out

    @channel.assertQueue 'fbp'
    @channel.consume 'fbp', deserialize

exports.Client = Client
exports.MessageBroker = MessageBroker
