// FetchHeadersHandler.swift
// A specialized handler for IMAP fetch headers operations
// 做法 B：解析已有 BODY[HEADER] 流式数据，提取 List-Unsubscribe / List-ID（MessageInfo 须已增加 listUnsubscribe/listId）

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP FETCH HEADERS command
final class FetchMessageInfoHandler: BaseIMAPCommandHandler<[MessageInfo]>, IMAPCommandHandler, @unchecked Sendable {
    /// Collected email headers
    private var messageInfos: [MessageInfo] = []

    /// BODY[HEADER] 流式数据缓冲，用于解析 List-Unsubscribe / List-ID
    private var headerBuffer = Data()
    /// 当前正在接收 header 流的那条消息在 messageInfos 中的下标
    private var streamingTargetIndex: Int?

    /// Handle a tagged OK response by succeeding the promise with the mailbox info
    /// - Parameter response: The tagged response
    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Call super to handle CLIENTBUG warnings
        super.handleTaggedOKResponse(response)

        // Succeed with the collected headers（最后一条消息的 header 流在此 flush）
        succeedWithResult(lock.withLock {
            if let idx = self.streamingTargetIndex, idx < self.messageInfos.count {
                self.applyParsedListHeaders(to: &self.messageInfos[idx], from: self.headerBuffer)
            }
            return self.messageInfos
        })
    }

    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.fetchFailed(String(describing: response.state)))
    }

    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override func processResponse(_ response: Response) -> Bool {
        // Call the base class implementation to buffer the response
        let handled = super.processResponse(response)

        // Process fetch responses
        if case .fetch(let fetchResponse) = response {
            processFetchResponse(fetchResponse)
        }

        // Return the result from the base class
        return handled
    }

    /// Process a fetch response
    /// - Parameter fetchResponse: The fetch response to process
    private func processFetchResponse(_ fetchResponse: FetchResponse) {
        switch fetchResponse {
        case .simpleAttribute(let attribute):
            // Process simple attributes (no sequence number)
            processMessageAttribute(attribute, sequenceNumber: nil)

        case .start(let sequenceNumber):
            lock.withLock {
                // 上一条消息的 BODY[HEADER] 已收完，解析并写回 listUnsubscribe / listId
                if let idx = streamingTargetIndex, idx < messageInfos.count {
                    applyParsedListHeaders(to: &messageInfos[idx], from: headerBuffer)
                }
                headerBuffer.removeAll(keepingCapacity: true)
                streamingTargetIndex = nil

                // Create a new header for this sequence number
                let messageInfo = MessageInfo(sequenceNumber: SequenceNumber(sequenceNumber.rawValue))
                self.messageInfos.append(messageInfo)
            }

        case .streamingBegin(_, _):
            // 接下来收到的 streamingBytes 属于当前最后一条消息
            lock.withLock {
                if !messageInfos.isEmpty {
                    streamingTargetIndex = messageInfos.count - 1
                    headerBuffer.removeAll(keepingCapacity: true)
                }
            }

        case .streamingBytes(let byteBuffer):
            // NIOIMAP 通常为 ByteBuffer；若关联类型是 Data，改为: let data / headerBuffer.append(data)
            lock.withLock {
                if let idx = streamingTargetIndex, idx < messageInfos.count {
                    headerBuffer.append(contentsOf: byteBuffer.readableBytesView)
                }
            }

        default:
            break
        }
    }

    /// 从 BODY[HEADER] 原始数据解析 List-Unsubscribe / List-ID 并写回 MessageInfo
    private func applyParsedListHeaders(to header: inout MessageInfo, from rawHeader: Data) {
        guard !rawHeader.isEmpty else { return }
        let (listUnsubscribe, listId) = Self.parseListHeaders(from: rawHeader)
        header.listUnsubscribe = listUnsubscribe
        header.listId = listId
    }

    /// RFC 5322 header 解析，提取 List-Unsubscribe / List-ID（含折叠行）
    private static func parseListHeaders(from data: Data) -> (ListUnsubscribe: String?, ListID: String?) {
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return (nil, nil)
        }
        let lines = raw.components(separatedBy: .newlines)
        var listUnsubscribe: String?
        var listId: String?
        var currentKey: String?
        var currentValue: String?

        func flush() {
            guard let key = currentKey else { return }
            let k = key.lowercased()
            if k == "list-unsubscribe" {
                listUnsubscribe = currentValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if k == "list-id" {
                listId = currentValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentKey = nil
            currentValue = nil
        }

        for line in lines {
            if line.isEmpty {
                flush()
                continue
            }
            if line.first == " " || line.first == "\t" {
                currentValue = (currentValue ?? "") + " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let colonIndex = line.firstIndex(of: ":") {
                flush()
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                currentKey = key
                currentValue = value
            }
        }
        flush()
        return (listUnsubscribe, listId)
    }

    /// Process a message attribute and update the corresponding email header
    /// - Parameters:
    ///   - attribute: The message attribute to process
    ///   - sequenceNumber: The sequence number of the message (if known)
    private func processMessageAttribute(_ attribute: MessageAttribute, sequenceNumber: SequenceNumber?) {
        // If we don't have a sequence number, we can't update a header
        guard let sequenceNumber = sequenceNumber else {
            // For attributes that come without a sequence number, we assume they belong to the last header
            lock.withLock {
                if let lastIndex = self.messageInfos.indices.last {
                    var header = self.messageInfos[lastIndex]
                    updateHeader(&header, with: attribute)
                    self.messageInfos[lastIndex] = header
                }
            }
            return
        }

        // Find or create a header for this sequence number
        let seqNum = SequenceNumber(sequenceNumber.value)
        lock.withLock {
            if let index = self.messageInfos.firstIndex(where: { $0.sequenceNumber == seqNum }) {
                var header = self.messageInfos[index]
                updateHeader(&header, with: attribute)
                self.messageInfos[index] = header
            } else {
                var header = MessageInfo(sequenceNumber: seqNum)
                updateHeader(&header, with: attribute)
                self.messageInfos.append(header)
            }
        }
    }

    /// Update an email header with information from a message attribute
    /// - Parameters:
    ///   - header: The header to update
    ///   - attribute: The attribute containing the information
    private func updateHeader(_ header: inout MessageInfo, with attribute: MessageAttribute) {
        switch attribute {
        case .envelope(let envelope):
            // Extract information from envelope
            if let subject = envelope.subject?.stringValue {
                header.subject = subject.decodeMIMEHeader()
            }

            // Handle from addresses - check if array is not empty
            if !envelope.from.isEmpty {
                header.from = formatAddress(envelope.from[0])
            }

            // Handle to addresses - capture all recipients
            header.to = envelope.to.map { formatAddress($0) }

            // Handle cc addresses - capture all recipients
            header.cc = envelope.cc.map { formatAddress($0) }

            // Handle bcc addresses - capture all recipients
            header.bcc = envelope.bcc.map { formatAddress($0) }

            if let date = envelope.date {
                let dateString = String(date)

                // Remove timezone comments in parentheses
                let cleanDateString = dateString.replacingOccurrences(of: "\\s*\\([^)]+\\)\\s*$", with: "", options: .regularExpression)

                // Create a date formatter for RFC 5322 dates
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)

                // Try different date formats commonly used in email headers
                let formats = [
                    "EEE, dd MMM yyyy HH:mm:ss Z",       // RFC 5322
                    "EEE, d MMM yyyy HH:mm:ss Z",        // RFC 5322 with single-digit day
                    "d MMM yyyy HH:mm:ss Z",             // Without day of week
                    "EEE, dd MMM yy HH:mm:ss Z"          // Two-digit year
                ]

                for format in formats {
                    formatter.dateFormat = format
                    if let parsedDate = formatter.date(from: cleanDateString) {
                        header.date = parsedDate
                        break
                    }
                }

                // If no format worked, log the issue instead of crashing
                if header.date == nil {
                    print("Warning: Failed to parse email date: \(dateString)")
                }
            }

            if let messageID = envelope.messageID {
                header.messageId = String(messageID)
            }

        case .uid(let uid):
            header.uid = UID(nio: uid)

        case .flags(let flags):
            header.flags = flags.map(self.convertFlag)

        case .body(let bodyStructure, _):
            if case .valid(let structure) = bodyStructure {
                header.parts = Array<MessagePart>(structure)
            }

        default:
            break
        }
    }

    /// Convert a NIOIMAPCore.Flag to our MessageFlag type
    private func convertFlag(_ flag: NIOIMAPCore.Flag) -> Flag {
        let flagString = String(flag)

        switch flagString.uppercased() {
        case "\\SEEN":
            return .seen
        case "\\ANSWERED":
            return .answered
        case "\\FLAGGED":
            return .flagged
        case "\\DELETED":
            return .deleted
        case "\\DRAFT":
            return .draft
        default:
            // For any other flag, treat it as a custom flag
            return .custom(flagString)
        }
    }

    /// Format an address for display
    /// - Parameter address: The address to format
    /// - Returns: A formatted string representation of the address
    private func formatAddress(_ address: EmailAddressListElement) -> String {
        switch address {
        case .singleAddress(let emailAddress):
            let name = emailAddress.personName?.stringValue.decodeMIMEHeader() ?? ""
            let mailbox = emailAddress.mailbox?.stringValue ?? ""
            let host = emailAddress.host?.stringValue ?? ""

            if !name.isEmpty {
                return "\"\(name)\" <\(mailbox)@\(host)>"
            } else {
                return "\(mailbox)@\(host)"
            }

        case .group(let group):
            let groupName = group.groupName.stringValue.decodeMIMEHeader()
            let members = group.children.map { formatAddress($0) }.joined(separator: ", ")
            return "\(groupName): \(members)"
        }
    }
}
