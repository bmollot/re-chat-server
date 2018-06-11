#!/usr/bin/env ruby

require 'socket'
require 'thread'
require 'optparse'

# Constants #
MAGIC_BYTES = "\x04\x17"
User = Struct.new(:socket, :name, :room)
Room = Struct.new(:name, :password)
Packet = Struct.new(:type, :payload)
Message = Struct.new(:context, :body)

# Parse and validate arguments (just port number)
port = nil

OptionParser.new do |opts|
  opts.banner = "server.rb [options]"
  opts.on("-p", "--port NUMBER", :REQUIRED, Integer, "Run the server on port NUMBER") do |p|
    port = p
  end
end.parse!

if port == nil
  puts "Missing --port argument"
  throw OptionParser::MissingArgument
end

if port <= 0
  puts "Invalid port #{port}"
  throw OptionParser::InvalidArgument
end

# Initialize global server state #
$users = Hash.new
$rooms = Hash.new

$counterLock = Mutex.new
$userCounter = 0

# Helper functions #

# @param c [TCPSocket]
# @return [Packet]
def readPacket(c)
  # Read header
  if c.recv(2) != MAGIC_BYTES
    puts "InvalidPacketError: Bytes are not sufficiently magical"
    return nil
  end
  payloadLength, typeCode = c.recv(5).unpack("L>C")
  type = nil
  payload = nil
  # Parse payload according to type
  if payloadLength > 0
    buf = c.recv(payloadLength)
  else
    buf = ""
  end
  case typeCode
  when 0xff
    type = :Hello
    if buf != "Hello"
      puts "InvalidPacketError: Hello packet has unexpected payload #{buf}"
      return nil
    end
    payload = buf
  when 0x17
    type = :Join
    strlen = buf[0].unpack("C")[0]
    roomName = buf.slice(1, strlen)
    payload = Room.new(roomName, nil)
    if buf.length > strlen + 1
      strlen = buf[strlen + 1].unpack("C")[0]
      roomPass = buf.slice(buf.length - strlen, strlen)
      payload.password = roomPass
    end
  when 0x18
    type = :Leave
  when 0x19
    type = :ListRooms
  when 0x1a
    type = :ListUsers
  when 0x1b
    type = :Nick
    strlen = buf[0].unpack("C")[0]
    newName = buf.slice(1, strlen)
    payload = newName
  when 0x1c
    type = :PrivateMessage
    offset = 0
    strlen = buf[offset].unpack("C")[0]
    offset += 1
    target = buf.slice(offset, strlen) # User
    offset += strlen
    strlen = buf.slice(offset, 2).unpack("S>")[0]
    offset += 2
    contents = buf.slice(offset, strlen)
    payload = Message.new(target, contents)
  when 0x1d
    type = :Message
    offset = 0
    strlen = buf[offset].unpack("C")[0]
    offset += 1
    target = buf.slice(offset, strlen) # Room
    offset += strlen
    strlen = buf.slice(offset, 2).unpack("S>")[0]
    offset += 2
    contents = buf.slice(offset, strlen)
    payload = Message.new(target, contents)
  else
    puts "InvalidPacketError: Unknown packet type #{typeCode.unpack("C")} with payload #{buf}"
    return nil
  end
  return Packet.new(type, payload)
end

# @param c [TCPSocket] Client connection
# @param t [Symbol]    Type
# @param p [Hash]      Payload
# @return [Boolean]    Success
def sendPacket(c, t, p)
  type = nil
  payload = nil
  case t
  when :PrivateMessage
    type = "\x1c"
    payload = [p[:user].length, p[:user], p[:msg].length, p[:msg]].pack("CA#{p[:user].length}S>A#{p[:msg].length}")
  when :Message
    type = "\x1d"
    payload = [p[:room].length, p[:room], p[:user].length, p[:user], p[:msg].length, p[:msg]].pack("CA#{p[:room].length}CA#{p[:user].length}S>A#{p[:msg].length}")
  when :Response
    type = "\xfe"
    if p[:error]
      error = "\x01"
    else
      error = "\x00"
    end
    if p[:data].instance_of? String
      data = p[:data]
    elsif p[:data].instance_of? Array
      data = ""
      p[:data].each do |x|
        data += [x.length, x].pack("CA#{x.length}")
      end
    else
      data = ""
    end
    payload = error + data
  else
    puts "Invalid packet type #{t} with payload #{p}"
    return false
  end

  c.send(MAGIC_BYTES + [payload.length].pack("L>") + type + payload, 0)
  return true
end

# @param c [TCPSocket]
def handleClient(c)
  # Wait for Hello
  hello = readPacket(c)
  if hello == nil
    return
  elsif hello.type != :Hello
    return
  end
  # Generate and send default nick
  $counterLock.lock
  userId = $userCounter
  $userCounter += 1
  $counterLock.unlock
  nick = "rand#{userId}"
  $users[userId] = User.new(c, nick, nil)
  sendPacket(c, :Response, {:error => false, :data => nick})

  loop do
    pack = readPacket(c)
    if pack == nil
      break
    end
    p pack
    p = pack.payload
    case pack.type
    when :Join
      room = $rooms[p.name]
      if room == nil
        $rooms[p.name] = p
        $users[userId].room = p.name
      elsif room.password == p.password
        $users[userId].room = room.name
      else
        sendPacket(c, :Response, {:error => true, :data => "Wrong password"})
        next
      end
      sendPacket(c, :Response, {:error => false})
    when :Leave
      if $users[userId].room == nil
        sendPacket(c, :Response, {:error => false})
        break
      else
        $users[userId].room = nil
        sendPacket(c, :Response, {:error => false})
      end
    when :ListRooms
      sendPacket(c, :Response, {:error => false, :data => $rooms.keys.map do |x|
          [x.length, x].pack("CA#{x.length}")
        end.join("")
      })
    when :ListUsers
      if $users[userId].room == nil
        sendPacket(c, :Response, {:error => false, :data => $users.values.map do |x|
            [x.name.length, x.name].pack("CA#{x.name.length}")
          end.join("")
        })
      else
        sendPacket(c, :Response, {:error => false, :data => $users.values.select {|x| x.room == $users[userId.room]}.map do |x|
            [x.name.length, x.name].pack("CA#{x.name.length}")
          end.join("")
        })
      end
    when :Nick
      $users[userId].name = p
      sendPacket(c, :Response, {:error => false})
    when :PrivateMessage
      sent = false
      $users.each_value do |user|
        if user.name == p.context
          sendPacket(user.socket, :PrivateMessage, {:user => $users[userId].name, :msg => p.body})
          sent = true
        end
      end
      if sent
        sendPacket(c, :Response, {:error => false})
      else
        sendPacket(c, :Response, {:error => true, :data => "User doesn't exist"})
      end
    when :Message
      room = $users[userId].room
      name = $users[userId].name
      if room != p.context
        sendPacket(c, :Response, {:error => true, :data => "Room mismatch (You can't speak in a room you're not in; you're not a good enough ventriloquist."})
      elsif room == nil || room == ""
        sendPacket(c, :Response, {:error => true, :data => "You're not in a room (You shout into the void. There is no response.)"})
      else
        sendPacket(c, :Response, {:error => false})
        $users.each do |id, user|
          if user.room == room and id != userId
            sendPacket(user.socket, :Message, {:room => room, :user => name, :msg => p.body})
          end
        end
      end
    else
      puts "InvalidPacketError: I don't know what to do with this #{pack}"
    end
  end
  puts "User #{userId} disconnected"
  $users.delete(userId)
end




# Bind to specified port and listen for connections
server = TCPServer.new(port)
loop do
  Thread.start(server.accept) do |client|
    handleClient(client)
    client.close
  end
end


