import nativesockets, net, selectors, tables, posix

import ../../consts
import ../../general
import ../../queues
import ../../tasks
import ../../timers
import ../tcpsocket

import router
import json
import msgpack4nim/msgpack2json

export tcpsocket, router

const TAG = "socketrpc"

type 
  RpcQueueHandle = ref object
    router: RpcRouter
    inQueue: QueueHandle_t
    outQueue: QueueHandle_t

proc rpcMsgPackQueueWriteHandler*(srv: TcpServerInfo[RpcQueueHandle], result: ReadyKey, sourceClient: Socket, qh: RpcQueueHandle) =
  raise newException(OSError, "the request to the OS failed")

proc rpcMsgPackQueueReadHandler*(srv: TcpServerInfo[RpcQueueHandle], result: ReadyKey, sourceClient: Socket, qh: RpcQueueHandle) =

  try:
    let msg = sourceClient.recv(qh.router.buffer, -1)

    if msg.len() == 0:
      raise newException(TcpClientDisconnected, "")
    else:
      var rcall: JsonNode = msgpack2json.toJsonNode(msg)
      
      discard xQueueSend(qh.inQueue, addr(rcall), TickType_t(1000)) 
      wasMoved(rcall)

      var res: JsonNode
      while xQueueReceive(qh.outQueue, addr(res), 0) == 0: 
        continue

      var rmsg: string = msgpack2json.fromJsonNode(res)
      sourceClient.send(rmsg)

  except TimeoutError:
    echo("control server: error: socket timeout: ", $sourceClient.getFd().int)

var rpcSocketId = 1

# Execute RPC Server #
proc execRpcSocketTask*(arg: pointer) {.exportc, cdecl.} =
  var qh: ptr RpcQueueHandle = cast[ptr RpcQueueHandle](arg)

  while true:
    try:
      timeBlockDebug("rpcTask"):
        logd(TAG,"exec rpc task wait: ")
        var rcall: JsonNode
        if xQueueReceive(qh.inQueue, addr(rcall), portMAX_DELAY) != 0: 
          # logd(TAG,"exec rpc task got: %s", repr(prcall.pointer))
          # if prcall == nil:
            # raise newException(ValueError, "bad data ptr in rpc queue!")

          # var rcall: JsonNode = rcall
    
          var res: JsonNode = qh.router.route( rcall )
    
          inc(rpcSocketId)
          discard xQueueSend(qh.outQueue, addr(res), TickType_t(1_000)) 
          # GC_ref(res)
          wasMoved(res)

    except:
      let
        e = getCurrentException()
        msg = getCurrentExceptionMsg()
      echo "Got exception ", repr(e), " with message ", msg



proc startRpcQueueSocketServer*(port: Port, router: var RpcRouter;
                                task_stack_depth = 8128'u32, task_priority = UBaseType_t(1), task_core = BaseType_t(-1)) =
  logd(TAG, "starting mpack rpc server: buffer: %s", $router.buffer)
  var qh: RpcQueueHandle = new(RpcQueueHandle)

  qh.router = router
  qh.inQueue = xQueueCreate(1, sizeof(JsonNode))
  qh.outQueue = xQueueCreate(1, sizeof(JsonNode))

  var rpcTask: TaskHandle_t
  discard xTaskCreatePinnedToCore(
                  execRpcSocketTask,
                  pcName="rpcqtask",
                  usStackDepth=task_stack_depth,
                  pvParameters=addr(qh),
                  uxPriority=task_priority,
                  pvCreatedTask=addr(rpcTask),
                  xCoreID=task_core)

  startSocketServer[RpcQueueHandle](
    port,
    readHandler=rpcMsgPackQueueReadHandler,
    writeHandler=rpcMsgPackQueueWriteHandler,
    data=qh)

