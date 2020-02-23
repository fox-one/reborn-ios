import Foundation
import Alamofire
import Starscream
import Gzip

public class WebSocketService {
    
    public static let didConnectNotification = Notification.Name("one.mixin.services.ws.connect")
    public static let didDisconnectNotification = Notification.Name("one.mixin.services.ws.disconnect")
    public static let pendingMessageUploadingDidBecomeAvailableNotification = Notification.Name("one.mixin.services.pending.msg.upload.available")
    
    public static let shared = WebSocketService()
    
    public var isConnected: Bool {
        return status == .connected
    }
    
    private let queue = DispatchQueue(label: "one.mixin.services.queue.websocket")
    private let queueSpecificKey = DispatchSpecificKey<Void>()
    private let messageQueue = DispatchQueue(label: "one.mixin.services.queue.websocket.message")
    private let refreshOneTimePreKeyInterval: TimeInterval = 3600 * 2
    
    private var host: String?
    private var socket: WebSocketProvider?
    private var heartbeat: HeartbeatService?
    
    private var status: Status = .disconnected {
        didSet {
            if !isAppExtension {
                AppGroupUserDefaults.websocketStatusInMainApp = status
            }
        }
    }
    private var networkWasRechableOnConnection = false
    private var messageHandlers = SafeDictionary<String, IncomingMessageHandler>()
    private var needsJobRestoration = true
    private var httpUpgradeSigningDate = Date()
    private var lastConnectionDate = Date()
    private var connectOnNetworkIsReachable = false

    internal init() {
        queue.setSpecific(key: queueSpecificKey, value: ())
        NotificationCenter.default.addObserver(self, selector: #selector(networkChanged), name: .NetworkDidChange, object: nil)
    }
    
    public func connect() {
        enqueueOperation {
            guard LoginManager.shared.isLoggedIn else {
                return
            }
            guard NetworkManager.shared.isReachable else {
                NotificationCenter.default.postOnMain(name: WebSocketService.didDisconnectNotification)
                return
            }
            guard self.status == .disconnected else {
                return
            }
            guard let url = URL(string: "wss://\(MixinServer.webSocketHost)") else {
                return
            }

            if isAppExtension && !AppGroupUserDefaults.canProcessMessagesInAppExtension {
                return
            }

            self.status = .connecting

            let socket = StarscreamWebSocket(host: MixinServer.webSocketHost, queue: self.queue)
            self.socket = socket
            self.socket?.delegate = self

            let heartbeat = HeartbeatService(socket: socket)
            heartbeat.onOffline = { [weak self] in
                self?.reconnect(sendDisconnectToRemote: true)
            }
            self.heartbeat = heartbeat

            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let headers = MixinRequest.getHeaders(request: request)
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            if isAppExtension {
                request.setValue("Mixin-Notification-Extension-1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            }

            self.networkWasRechableOnConnection = NetworkManager.shared.isReachable
            self.lastConnectionDate = Date()
            self.httpUpgradeSigningDate = Date()
            self.socket?.serverTime = nil
            self.socket?.connect(request: request)
        }
    }
    
    public func disconnect() {
        enqueueOperation {
            guard self.status == .connecting || self.status == .connected else {
                return
            }
            self.connectOnNetworkIsReachable = false
            self.heartbeat?.stop()

            self.socket?.disconnect(closeCode: CloseCode.exit)
            self.needsJobRestoration = true
            ConcurrentJobQueue.shared.cancelAllOperations()
            self.messageHandlers.removeAll()
            self.status = .disconnected
        }
    }

    public func connectIfNeeded() {
        enqueueOperation {
            guard LoginManager.shared.isLoggedIn, NetworkManager.shared.isReachable else {
                return
            }
            if self.status == .disconnected {
                self.connect()
            } else if self.status == .connected && !(self.socket?.isConnected ?? false) {
                self.reconnect(sendDisconnectToRemote: true)
            }
        }
    }
    
    internal func respondedMessage(for message: BlazeMessage) throws -> BlazeMessage? {
        return try messageQueue.sync {
            guard LoginManager.shared.isLoggedIn else {
                return nil
            }
            var response: BlazeMessage?
            var err = APIError.createTimeoutError()
            
            let semaphore = DispatchSemaphore(value: 0)
            messageHandlers[message.id] = { (jobResult) in
                switch jobResult {
                case let .success(blazeMessage):
                    response = blazeMessage
                case let .failure(error):
                    if error.code == 10002 {
                        if let param = message.params, let messageId = param.messageId, messageId != messageId.lowercased() {
                            MessageDAO.shared.deleteMessage(id: messageId)
                            JobDAO.shared.removeJob(jobId: message.id)
                        }
                    }
                    if let conversationId = message.params?.conversationId {
                        Logger.write(conversationId: conversationId, log: "[WebSocketService][RespondedMessage]...\(error.debugDescription)")
                    }
                    err = error
                }
                semaphore.signal()
            }
            if !send(message: message) {
                messageHandlers.removeValue(forKey: message.id)
                throw err
            }

            if semaphore.wait(timeout: .now() + .seconds(5)) == .timedOut, let conversationId = message.params?.conversationId {
                Logger.write(conversationId: conversationId, log: "[WebSocketService][RespondedMessage]...semaphore timeout...")
            }
            
            guard let blazeMessage = response else {
                throw err
            }
            return blazeMessage
        }
    }
    
}

extension WebSocketService: WebSocketProviderDelegate {

    func websocketDidReceivePong(socket: WebSocketProvider) {
        enqueueOperation {
            self.heartbeat?.websocketDidReceivePong()
        }
    }

    func websocketDidConnect(socket: WebSocketProvider) {
        guard status == .connecting else {
            return
        }

        if let responseServerTime = socket.serverTime, let serverTime = Double(responseServerTime), serverTime > 0 {
            let signingDate = httpUpgradeSigningDate
            let serverDate =  Date(timeIntervalSince1970: serverTime / 1000000000)
            if abs(serverDate.timeIntervalSince(signingDate)) > 300 {
                if -signingDate.timeIntervalSinceNow > 60 {
                    reconnect(sendDisconnectToRemote: true)
                } else {
                    AppGroupUserDefaults.Account.isClockSkewed = true
                    disconnect()
                    NotificationCenter.default.postOnMain(name: MixinService.clockSkewDetectedNotification)
                }
                return
            }
        }


        status = .connected
        NotificationCenter.default.postOnMain(name: WebSocketService.didConnectNotification, object: self)
        ReceiveMessageService.shared.processReceiveMessages()
        requestListPendingMessages()
        ConcurrentJobQueue.shared.resume()
        heartbeat?.start()

        if let date = AppGroupUserDefaults.Crypto.oneTimePrekeyRefreshDate, -date.timeIntervalSinceNow > refreshOneTimePreKeyInterval {
            ConcurrentJobQueue.shared.addJob(job: RefreshAssetsJob())
            ConcurrentJobQueue.shared.addJob(job: RefreshOneTimePreKeysJob())
        }
        AppGroupUserDefaults.Crypto.oneTimePrekeyRefreshDate = Date()
        ConcurrentJobQueue.shared.addJob(job: RefreshOffsetJob())
    }
    
    func websocketDidDisconnect(socket: WebSocketProvider, isSwitchNetwork: Bool) {
        guard status == .connecting || status == .connected else {
            return
        }

        if isSwitchNetwork {
            MixinServer.toggle(currentWebSocketHost: host)
        }

        reconnect(sendDisconnectToRemote: false)
    }

    func websocketDidReceiveData(socket: WebSocketProvider, data: Data) {
        guard data.isGzipped, let unzipped = try? data.gunzipped() else {
            return
        }
        guard let message = try? JSONDecoder.default.decode(BlazeMessage.self, from: unzipped) else {
            return
        }
        if let error = message.error {
            if let handler = messageHandlers[message.id] {
                messageHandlers.removeValue(forKey: message.id)
                handler(.failure(error))
            }
            let needsLogout = message.action == BlazeMessageAction.error.rawValue
                && error.code == 401
                && !AppGroupUserDefaults.Account.isClockSkewed
            if needsLogout {
                LoginManager.shared.logout(from: "WebSocketService")
            }
        } else {
            if let handler = messageHandlers[message.id] {
                messageHandlers.removeValue(forKey: message.id)
                handler(.success(message))
            }
            if message.data != nil {
                if message.isReceiveMessageAction() {
                    ReceiveMessageService.shared.receiveMessage(blazeMessage: message)
                } else {
                    guard let data = message.toBlazeMessageData() else {
                        return
                    }
                    SendMessageService.shared.sendAckMessage(messageId: data.messageId, status: .READ)
                }
            }
        }
    }
    
}

extension WebSocketService {
    
    public enum Status: String {
        case disconnected
        case connecting
        case connected
    }
    
    private typealias IncomingMessageHandler = (APIResult<BlazeMessage>) -> Void
    
    private func enqueueOperation(_ closure: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueSpecificKey) == nil {
            queue.async(execute: closure)
        } else {
            closure()
        }
    }

    @objc private func networkChanged() {
        networkBecomesReachable()
    }
    
    private func networkBecomesReachable() {
        enqueueOperation {
            guard LoginManager.shared.isLoggedIn, NetworkManager.shared.isReachable, self.connectOnNetworkIsReachable else {
                return
            }
            self.connect()
        }
    }
    
    private func reconnect(sendDisconnectToRemote: Bool) {
        enqueueOperation {
            ReceiveMessageService.shared.refreshRefreshOneTimePreKeys = [String: TimeInterval]()
            for handler in self.messageHandlers.values {
                handler(.failure(APIError.createTimeoutError()))
            }
            self.messageHandlers.removeAll()
            ConcurrentJobQueue.shared.suspend()
            self.heartbeat?.stop()
            if sendDisconnectToRemote {
                self.socket?.disconnect(closeCode: CloseCode.failure)
            }
            self.status = .disconnected
            NotificationCenter.default.postOnMain(name: WebSocketService.didDisconnectNotification, object: self)
            
            let shouldConnectImmediately = NetworkManager.shared.isReachable
                && LoginManager.shared.isLoggedIn
                && (!self.networkWasRechableOnConnection || -self.lastConnectionDate.timeIntervalSinceNow >= 1)
            if shouldConnectImmediately {
                self.connectOnNetworkIsReachable = false
                self.connect()
            } else {
                self.status = .disconnected
                self.connectOnNetworkIsReachable = true
            }
        }
    }
    
    @discardableResult
    private func send(message: BlazeMessage) -> Bool {
        guard let socket = socket, status == .connected else {
            return false
        }
        guard let data = try? JSONEncoder.default.encode(message), let gzipped = try? data.gzipped() else {
            return false
        }
        socket.send(data: gzipped)
        return true
    }
    
    private func requestListPendingMessages() {
        let message = BlazeMessage(action: BlazeMessageAction.listPendingMessages.rawValue)
        messageHandlers[message.id] = { (result) in
            switch result {
            case .success:
                if self.needsJobRestoration {
                    self.needsJobRestoration = false
                    DispatchQueue.global().async {
                        NotificationCenter.default.post(name: WebSocketService.pendingMessageUploadingDidBecomeAvailableNotification, object: self)
                        SendMessageService.shared.processMessages()
                    }
                    ConcurrentJobQueue.shared.restoreJobs()
                }
            case .failure:
                self.queue.asyncAfter(deadline: .now() + 2, execute: {
                    guard let socket = self.socket, socket.isConnected else {
                        return
                    }
                    self.requestListPendingMessages()
                })
            }
        }
        send(message: message)
    }
    
}
