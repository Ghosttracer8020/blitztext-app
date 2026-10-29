import AVFoundation
import XCTest

final class LiveTranscriptionTests: XCTestCase {
    // MARK: - Keywords

    func testSanitizeStripsAngleBracketsAndLineBreaks() {
        let result = TranscriptionKeywords.sanitize(["Park<our>ONE", "Zeile\neins\r\nzwei", "  Blitz   text  "])
        XCTAssertEqual(result, ["Park our ONE", "Zeile eins zwei", "Blitz text"])
        for term in result {
            XCTAssertFalse(term.contains("<") || term.contains(">") || term.contains("\n") || term.contains("\r"))
        }
    }

    func testSanitizeDropsEmptiesAndDuplicates() {
        XCTAssertEqual(TranscriptionKeywords.sanitize(["", "  ", "<>", "Ben", "ben", "BEN", "Anna"]), ["Ben", "Anna"])
    }

    func testSanitizeCapsLengthAndCount() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(TranscriptionKeywords.sanitize([long]).first?.count, TranscriptionKeywords.maxLength)
        let many = (0..<500).map { "term\($0)" }
        XCTAssertEqual(TranscriptionKeywords.sanitize(many).count, TranscriptionKeywords.maxCount)
    }

    func testPromptListsLimitedTermsAndIsNilWithoutTerms() {
        XCTAssertNil(TranscriptionKeywords.prompt(forKeywords: []))
        XCTAssertEqual(TranscriptionKeywords.prompt(forKeywords: ["A", "B"]), "Eigennamen und Begriffe: A, B")
        let prompt = TranscriptionKeywords.prompt(forKeywords: (0..<50).map { "Begriff\($0)" })
        XCTAssertLessThanOrEqual(prompt?.count ?? 0, TranscriptionKeywords.maxPromptLength)
        XCTAssertFalse(prompt?.contains("Begriff20") ?? true)
    }

    func testLanguagesFromSetting() {
        XCTAssertEqual(TranscriptionKeywords.languages(from: " DE "), ["de"])
        XCTAssertEqual(TranscriptionKeywords.languages(from: "auto"), [])
        XCTAssertEqual(TranscriptionKeywords.languages(from: ""), [])
        XCTAssertEqual(TranscriptionKeywords.languages(from: nil), [])
    }

    // MARK: - Client events

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testSessionUpdateWithOptionalFields() throws {
        let request = LiveTranscriptionRequest.make(customTerms: ["Blitztext", "ParkourONE"], language: "de")
        let event = object(LiveEvents.sessionUpdate(request, includeOptionalFields: true))
        XCTAssertEqual(event["type"] as? String, "session.update")
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertEqual((input["noise_reduction"] as? [String: Any])?["type"] as? String, "near_field")
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["languages"] as? [String], ["de"])
        XCTAssertNil(transcription["language"])
        XCTAssertEqual(transcription["keywords"] as? [String], ["Blitztext", "ParkourONE"])
        XCTAssertEqual(transcription["prompt"] as? String, "Eigennamen und Begriffe: Blitztext, ParkourONE")
        XCTAssertEqual(transcription["delay"] as? String, "low")
    }

    func testSessionUpdateWithoutOptionalFieldsOrTerms() throws {
        let request = LiveTranscriptionRequest.make(customTerms: [], language: "de")
        let event = object(LiveEvents.sessionUpdate(request, includeOptionalFields: false))
        let input = try XCTUnwrap(((event["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertNil(input["noise_reduction"])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertNil(transcription["delay"])
        XCTAssertNil(transcription["keywords"])
        XCTAssertNil(transcription["prompt"])
    }

    func testAppendAndCommitEvents() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let append = object(LiveEvents.append(pcm))
        XCTAssertEqual(append["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(append["audio"] as? String, pcm.base64EncodedString())
        XCTAssertEqual(object(LiveEvents.commit)["type"] as? String, "input_audio_buffer.commit")
    }

    // MARK: - Server events

    func testParsesServerEvents() {
        XCTAssertEqual(LiveEvents.parse(#"{"type":"session.created"}"#), .sessionCreated)
        XCTAssertEqual(LiveEvents.parse(#"{"type":"session.updated","session":{}}"#), .sessionUpdated)
        XCTAssertEqual(LiveEvents.parse(#"{"type":"input_audio_buffer.committed","item_id":"item_1"}"#), .committed(itemID: "item_1"))
        XCTAssertEqual(
            LiveEvents.parse(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_1","delta":"Hal"}"#),
            .delta(itemID: "item_1", text: "Hal")
        )
        XCTAssertEqual(
            LiveEvents.parse(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","transcript":"Hallo Welt"}"#),
            .completed(itemID: "item_1", transcript: "Hallo Welt")
        )
        XCTAssertEqual(
            LiveEvents.parse(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"i","error":{"message":"boom"}}"#),
            .transcriptionFailed(message: "boom")
        )
        XCTAssertEqual(
            LiveEvents.parse(#"{"type":"error","error":{"message":"Unknown parameter: delay","type":"invalid_request_error","code":"unknown_parameter"}}"#),
            .error(message: "Unknown parameter: delay", code: "unknown_parameter")
        )
        XCTAssertEqual(LiveEvents.parse(#"{"type":"rate_limits.updated"}"#), .other(type: "rate_limits.updated"))
        XCTAssertEqual(LiveEvents.parse("not json"), .unparsable)
        XCTAssertEqual(LiveEvents.parse(#"{"no":"type"}"#), .unparsable)
    }

    func testUnsupportedOptionalFieldDetection() {
        XCTAssertTrue(LiveEvents.isUnsupportedOptionalFieldError("Unknown parameter: 'session.audio.input.transcription.delay'."))
        XCTAssertTrue(LiveEvents.isUnsupportedOptionalFieldError("noise_reduction is not supported for this model"))
        XCTAssertFalse(LiveEvents.isUnsupportedOptionalFieldError("Invalid keywords: must not contain '<'"))
        // Differently phrased rejections still trigger the retry.
        XCTAssertTrue(LiveEvents.isUnsupportedOptionalFieldError("Invalid value: 'near_field'."))
        XCTAssertTrue(LiveEvents.isUnsupportedOptionalFieldError("Unknown parameter: 'session.audio.input.noise'."))
        XCTAssertTrue(LiveEvents.isUnsupportedOptionalFieldError("Bad request", code: "invalid_request_error"))
        XCTAssertFalse(LiveEvents.isUnsupportedOptionalFieldError("Incorrect API key", code: "invalid_api_key"))
    }

    func testErrorTypeStandsInForMissingCode() {
        XCTAssertEqual(
            LiveEvents.parse(#"{"type":"error","error":{"message":"x","type":"invalid_request_error"}}"#),
            .error(message: "x", code: "invalid_request_error")
        )
    }

    func testResultIdleTimeoutScalesWithRecordingLengthAndIsCapped() {
        XCTAssertEqual(LiveTimeouts.resultIdle(forAudioSeconds: 0), 4, accuracy: 0.001)
        XCTAssertEqual(LiveTimeouts.resultIdle(forAudioSeconds: 30), 7, accuracy: 0.001)
        XCTAssertEqual(LiveTimeouts.resultIdle(forAudioSeconds: 600), LiveTimeouts.resultIdleMax, accuracy: 0.001)
    }

    func testEngineStopFlag() {
        let flag = EngineStopFlag()
        XCTAssertFalse(flag.isSet)
        flag.set()
        XCTAssertTrue(flag.isSet)
    }

    // MARK: - Chunking

    func testChunkerEmitsHundredMillisecondChunks() {
        XCTAssertEqual(PCMChunker.defaultChunkBytes, 4800)
        var chunker = PCMChunker()
        XCTAssertTrue(chunker.push(Data(count: 4000)).isEmpty)
        let chunks = chunker.push(Data(count: 6000))
        XCTAssertEqual(chunks.map(\.count), [4800, 4800])
        XCTAssertEqual(chunker.flush()?.count, 400)
        XCTAssertNil(chunker.flush())
    }

    func testChunkerKeepsByteOrder() {
        var chunker = PCMChunker(chunkBytes: 4)
        let first = chunker.push(Data([1, 2, 3]))
        let second = chunker.push(Data([4, 5, 6, 7, 8, 9]))
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual((first + second).map { [UInt8]($0) }, [[1, 2, 3, 4], [5, 6, 7, 8]])
        XCTAssertEqual(chunker.flush().map { [UInt8]($0) }, [9])
    }

    // MARK: - PCM conversion

    func testConverterResamplesFloatMonoTo24kInt16() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(PCM16Converter(inputFormat: format))
        var total = 0
        for _ in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            for index in 0..<4800 {
                buffer.floatChannelData?[0][index] = 0.5 * sin(Float(index) * 0.05)
            }
            let data = converter.convert(buffer)
            XCTAssertEqual(data.count % 2, 0)
            total += data.count
        }
        // 10 x 100 ms at 48 kHz -> about 1 s at 24 kHz = 48000 bytes (resampler latency tolerated).
        XCTAssertEqual(Double(total), 48_000, accuracy: 1_000)
    }

    func testConverterDownmixesStereo() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 2, interleaved: false))
        let converter = try XCTUnwrap(PCM16Converter(inputFormat: format))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400))
        buffer.frameLength = 2400
        for channel in 0..<2 {
            for index in 0..<2400 { buffer.floatChannelData?[channel][index] = 0.25 }
        }
        let data = converter.convert(buffer)
        XCTAssertEqual(data.count, 2400 * 2, accuracy: 200)
    }

    // MARK: - Fallback decision

    func testUsesLiveTranscriptWhenPresent() {
        XCTAssertEqual(LiveFallbackDecision.decide(.success(" Hallo Welt \n"), recordingDuration: 2), .useLive("Hallo Welt"))
    }

    func testEmptyTranscriptFallsBackOnlyForRecordingsThatCanHoldSpeech() {
        XCTAssertEqual(LiveFallbackDecision.decide(.success("  "), recordingDuration: 2), .fallbackToBatch(reason: "empty-transcript"))
        XCTAssertEqual(LiveFallbackDecision.decide(.success(""), recordingDuration: 0.1), .useLive(""))
    }

    func testFallsBackWhenLiveAudioCoversTooLittleOfTheRecording() {
        XCTAssertEqual(
            LiveFallbackDecision.decide(.success("Hallo"), recordingDuration: 10, liveAudioSeconds: 8),
            .fallbackToBatch(reason: "audio-gap")
        )
        XCTAssertEqual(
            LiveFallbackDecision.decide(.success("Hallo"), recordingDuration: 10, liveAudioSeconds: 9.5),
            .useLive("Hallo")
        )
    }

    func testEveryFailureFallsBackExceptCancel() {
        let failures: [LiveFailure] = [.notConfigured, .unauthorized, .connect, .server(code: "x"), .transcriptionFailed, .timeout, .noAudio]
        for failure in failures {
            guard case .fallbackToBatch(let reason) = LiveFallbackDecision.decide(.failure(failure), recordingDuration: 3) else {
                return XCTFail("\(failure) should fall back")
            }
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertEqual(LiveFallbackDecision.decide(.failure(.cancelled), recordingDuration: 3), .cancelled)
    }
}

private func XCTAssertEqual(_ lhs: Int, _ rhs: Int, accuracy: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(lhs - rhs), accuracy, file: file, line: line)
}
