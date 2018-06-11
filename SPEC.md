# General Rules
A connection between Client and Server is a regular TCP connection initiated by the Client.
In all packets besides the first packet and its ACK, the following Options will be set:
- NOP
- NOP
- Timestamps

# Establishing the Connection
The Client is to initiate a TCP session with the following Options set:
- Maximum segment size: 1460 bytes
- SACK permitted
- Timestamps
- NOP
- Window scale: 7
Those options will then be sent back unchanged in the Server's ACK.

# Packet Structure
Constant (2 bytes) | Length (4 bytes) | Type (1 byte) | Payload
- Constant
Always 0x04 17
- Length
Payload size in bytes in network order
- Type
Indicates the purpose of this packet, types are listed below
- Payload
A variable-length byte sequence. It's significance varies with packet type. Payload formats for each packet type are documented below.

# Common encodings
- LS: Byte-Length String
<1 byte string length> <ASCII encoded string>
- LLS: Short-Length String
<2 byte string length> <ASCII encoded string>

# Packet Types

## Client ##
Each packet type is documented with the following format:
- <packet code>: <packet name>
<payload format>

- 0xff: Hello
  ASCII "Hello"
- 0x17: Join Room
  <LS room name> optional<LS room password>
- 0x18: Leave
  No payload
- 0x19: List Rooms
  No payload
- 0x1a: List Users
  No payload
- 0x1b: Nick
  <LS new nick>
- 0x1c: Private Message
  <LS target user name> <LLS message>
- 0x1d: Message
  <LS room name> <LLS message>

## Server ##
- 0x1c: Private Message
  <LS user name> <LLS message>
- 0x1d: Message
  <LS room name> <LS user name> <LLS message>
- 0xfe: Response
  This is the type of all packets sent in response to some action taken by the client. Payloads are mostly different depending on which type of Client packet they are sent in response to. The only consistent part is the first byte, which is an error code. A value of 0x00 indicates a success, 0x01 an error. The rest of the payload is described for each corresponding client message below
  - Hello
    ASCII assigned nickname
  - Join Room (success)
    0x00
  - Join Room (failure)
    ASCII error message
  - Leave
    0x00
  - Message (success)
    0x00
  - List *
    Sequence of LS encoded * names, no delimiters
  - Nick
    0x00
  - Private Message
    0x00
  - Private Message (failure)
    ASCII error message
  - Message
    0x00
  - Message (failure)
    ASCII error message
