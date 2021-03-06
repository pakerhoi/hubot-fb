try
  {Robot, Adapter, TextMessage, User} = require 'hubot'
catch
  prequire = require('parent-require')
  {Robot, Adapter, TextMessage, User} = prequire 'hubot'

Mime = require 'mime'
crypto = require 'crypto'
inspect = require('util').inspect
dashbot = require('dashbot')(process.env.DASHBOT_API_KEY).facebook
async = require('async')
_ = require('lodash')

class FBMessenger extends Adapter

  constructor: ->
    super

    @page_id = process.env['FB_PAGE_ID']
    @app_id = process.env['FB_APP_ID']
    @app_secret = process.env['FB_APP_SECRET']

    @token = process.env['FB_PAGE_TOKEN']
    @vtoken = process.env['FB_VERIFY_TOKEN'] or crypto.randomBytes(16).toString('hex')

    @routeURL = process.env['FB_ROUTE_URL'] or '/hubot/fb'
    @webhookURL = process.env['FB_WEBHOOK_BASE'] + @routeURL

    _sendImages = process.env['FB_SEND_IMAGES']
    if _sendImages is undefined
      @sendImages = true
    else
      @sendImages = _sendImages is 'true'

    @autoHear = process.env['FB_AUTOHEAR'] is 'true'

    @apiURL = 'https://graph.facebook.com/v2.6'
    @pageURL = @apiURL + '/' + @page_id
    @messageEndpoint = @pageURL + '/messages?access_token=' + @token
    @subscriptionEndpoint = @pageURL + '/subscribed_apps?access_token=' + @token
    @appAccessTokenEndpoint = @apiURL + '/oauth/access_token?client_id=' + @app_id + '&client_secret=' + @app_secret + '&grant_type=client_credentials'
    @setWebhookEndpoint = @pageURL + '/subscriptions'

    @msg_maxlength = 320

  send: (envelope, strings...) ->
    callback = undefined
    copy = strings.slice(0)
    if typeof(copy[copy.length - 1]) == 'function'
      callback = copy.pop()

    self = @

    #    if envelope.fb?.richMsg?
    #      @_sendRich envelope.user.id, envelope.fb.richMsg, (err) ->
    #    else
    async.eachSeries \
      strings, \
      ((string, callback) -> self._sendText envelope.user.id, string, callback), \
      (err) ->
        if( err )
          console.log 'Messages sent failed'
        else
          if envelope.fb?.richMsg?
            self._sendRich envelope.user.id, envelope.fb.richMsg, (err) ->
              console.log('messages sent successfully')
              if callback
                callback()
          else
            console.log('messages sent successfully')
            if callback
              callback()


  _sendText: (user, msg, callback) ->
    data = {
      recipient: {id: user},
      message: {}
    }

    if @sendImages
      mime = Mime.lookup(msg)

      if mime is "image/jpeg" or mime is "image/png" or mime is "image/gif"
        data.message.attachment = {type: "image", payload: {url: msg}}
      else
        data.message.text = msg.substring(0, @msg_maxlength)
    else
      data.message.text = msg

    @_sendAPI data, callback

  _sendRich: (user, richMsg, callback) ->
    data = {
      recipient: {id: user},
      message: richMsg
    }
    @_sendAPI data, callback

  _sendAPI: (data, callback) ->
    rawData = data
    self = @

    data = JSON.stringify(data)
    console.log '>>>Sending' + data

    self.robot.http(self.messageEndpoint)
    .query({access_token: self.token})
    .header('Content-Type', 'application/json')
    .post(data) (error, response, body) ->
    # Dashbot log outgoing
      requestData =
        url: self.messageEndpoint
        qs: {access_token: self.token}
        method: 'POST'
        json: rawData

      try
        dashbot.logOutgoing(requestData, JSON.parse body)
      catch e
        self.robot.logger.debug 'error in Dashbot:', e

      if error
        self.robot.logger.error 'Error sending message: #{error}'
        return callback(error)
      unless response.statusCode in [200, 201]
        self.robot.logger.error "Send request returned status " +
            "#{response.statusCode}. data='#{data}'"
        self.robot.logger.error body
        return callback('Error sending message')

      return callback()

  reply: (envelope, strings...) ->
    @send envelope, strings...

  _receiveAPI: (event) ->
    self = @

    im_page_id = event.recipient.id #page
    im_user_id = event.sender.id #user

    im_id = 1 # facebook IM id

    self.robot.Users.getUserByIM im_id, im_page_id, im_user_id, (err, user) ->
      if(err)
        self.robot.logger.debug 'error:', err

      unless user?
        self.robot.logger.debug "User doesn't exist, creating"
        self._getUser im_user_id, im_page_id, (user_data) ->
          self.robot.Users.createUserFromFacebook user_data, (err, new_user) ->
            if(err)
              self.robot.logger.debug 'error:', err

            self._dispatch event, new_user
      else
        self.robot.logger.debug "User exists"

        if not user.id or not user.room
          user.id = im_user_id
          user.room = im_page_id
          self.robot.Users.updateUser user, (err, updated_user) ->
            if(err)
              self.robot.logger.debug 'error:', err

            self._dispatch event, updated_user
        else
          self._dispatch event, user

#      user = self.robot.brain.data.users[event.sender.id]

  _dispatch: (event, user) ->
    envelope = {
      event: event,
      user: user,
      room: event.recipient.id
    }

    if event.message?
      @_processMessage event, envelope
    else if event.postback?
      @_processPostback event, envelope
    else if event.delivery?
      @_processDelivery event, envelope
    else if event.optin?
      @_processOptin event, envelope

  _processMessage: (event, envelope) ->
    @robot.logger.debug inspect event.message
    if event.message.attachments?
      envelope.attachments = event.message.attachments
      @robot.emit "fb_richMsg", envelope
      @_processAttachment event, envelope, attachment for attachment in envelope.attachments
    if event.message.text?
      text = if @autoHear then @_autoHear event.message.text, envelope.room else event.message.text

      # TODO: Quick reply payload override the text
      if event.message.quick_reply?.payload
        text = event.message.quick_reply?.payload

      msg = new TextMessage envelope.user, text, event.message.mid
      @receive msg
      @robot.logger.info "Reply message to room/message: " + envelope.user.name + "/" + event.message.mid

  _autoHear: (text, chat_id) ->
# If it is a private chat, automatically prepend the bot name if it does not exist already.
    if (chat_id > 0)
# Strip out the stuff we don't need.
      text = text.replace(new RegExp('^@?' + @robot.name.toLowerCase(), 'gi'), '');
      text = text.replace(new RegExp('^@?' + @robot.alias.toLowerCase(), 'gi'), '') if @robot.alias
      text = @robot.name + ' ' + text

    return text

  _processAttachment: (event, envelope, attachment) ->
    unique_envelope = {
      event: event,
      user: envelope.user,
      room: envelope.room,
      attachment: attachment
    }
    @robot.emit "fb_richMsg_#{attachment.type}", unique_envelope

  _processPostback: (event, envelope) ->
    envelope.payload = event.postback.payload
    @robot.emit "fb_postback", envelope

  _processDelivery: (event, envelope) ->
    @robot.emit "fb_delivery", envelope

  _processOptin: (event, envelope) ->
    envelope.ref = event.optin.ref
    @robot.emit "fb_optin", envelope
    @robot.emit "fb_authentication", envelope

  _getUser: (userId, page, callback) ->
    self = @

    @robot.http(@apiURL + '/' + userId)
    .query({
      fields: "first_name,last_name,profile_pic,locale,timezone,gender",
      access_token: self.token
    })
    .get() (error, response, body) ->
      if error
        self.robot.logger.error 'Error getting user profile: #{error}'
        return
      unless response.statusCode is 200
        self.robot.logger.error "Get user profile request returned status " +
            "#{response.statusCode}. data='#{body}'"
        self.robot.logger.error body
        return
      userData = JSON.parse body

      userData.name = userData.first_name
      userData.room = page

      user = new User userId, userData
      #      self.robot.brain.data.users[userId] = user

      callback user


  run: ->
    self = @

    unless @token
      @emit 'error', new Error 'The environment variable "FB_PAGE_TOKEN" is required. See https://github.com/chen-ye/hubot-fb/blob/master/README.md for details.'

    unless @page_id
      @emit 'error', new Error 'The environment variable "FB_PAGE_ID" is required. See https://github.com/chen-ye/hubot-fb/blob/master/README.md for details.'

    unless @app_id
      @emit 'error', new Error 'The environment variable "FB_APP_ID" is required. See https://github.com/chen-ye/hubot-fb/blob/master/README.md for details.'

    unless @app_secret
      @emit 'error', new Error 'The environment variable "FB_APP_SECRET" is required. See https://github.com/chen-ye/hubot-fb/blob/master/README.md for details.'

    unless process.env['FB_WEBHOOK_BASE']
      @emit 'error', new Error 'The environment variable "FB_WEBHOOK_BASE" is required. See https://github.com/chen-ye/hubot-fb/blob/master/README.md for details.'

    @robot.http(@subscriptionEndpoint)
    .query({access_token: self.token})
    .post() (error, response, body) ->
      if error
        self.robot.logger.error "Error subscribing app to page: " + error
        process.exit()
        return

      self.robot.logger.info "subscribed app to page: response: " + response+ ' body: ' + body

    @robot.router.get [@routeURL], (req, res) ->
      if req.param('hub.mode') == 'subscribe' and req.param('hub.verify_token') == self.vtoken
        res.send req.param('hub.challenge')
        self.robot.logger.info "successful webhook verification"
      else
        res.send 400

    @robot.router.post [@routeURL], (req, res) ->
      res.send 200

      # Dashbot log incoming
      try
        dashbot.logIncoming req.body
      catch e
        self.robot.logger.debug 'error in Dashbot:', e

      self.robot.logger.debug "Received payload: " + JSON.stringify(req.body)
      messaging_events = req.body.entry[0].messaging
      self._receiveAPI event for event in messaging_events

    @robot.http(@appAccessTokenEndpoint)
    .get() (error, response, body) ->
      if error
        self.robot.logger.error "Error getting app access token: " + error
        process.exit()
        return

      self.robot.logger.info "app access token response: "+ response + " body: "  + body

      parsed_body = JSON.parse body
      self.app_access_token = parsed_body['access_token'] or body.split("=").pop()
      self.robot.http(self.setWebhookEndpoint)
      .query(
        object: 'page',
        callback_url: self.webhookURL
        fields: 'messaging_optins, messages, message_deliveries, messaging_postbacks'
        verify_token: self.vtoken
        access_token: self.app_access_token
      )
      .post() (error2, response2, body2) ->
        self.robot.logger.info "FB webhook set/updated: " + body2

    @robot.logger.info "FB-adapter initialized"
    @emit "connected"
    @robot.emit "fb_initialized", @apiURL, @token

exports.use = (robot) ->
  new FBMessenger robot
