package de.sharedinbox.core.jmap

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** RFC 8620 §3.3 — API request envelope */
@Serializable
data class JmapRequest(
    val using: List<String>,
    val methodCalls: List<MethodCall>,
)

/**
 * RFC 8620 §3.2 — A method call is a JSON 3-tuple: ["name", {arguments}, "clientId"].
 * The custom serializer handles the array wire format.
 */
@Serializable(with = MethodCallSerializer::class)
data class MethodCall(
    val name: String,
    val arguments: JsonObject,
    val clientId: String,
)

object MethodCallSerializer : KSerializer<MethodCall> {
    private val delegate = ListSerializer(JsonElement.serializer())
    override val descriptor: SerialDescriptor = delegate.descriptor

    override fun serialize(encoder: Encoder, value: MethodCall) {
        encoder.encodeSerializableValue(
            delegate,
            listOf(JsonPrimitive(value.name), value.arguments, JsonPrimitive(value.clientId)),
        )
    }

    override fun deserialize(decoder: Decoder): MethodCall {
        val list = decoder.decodeSerializableValue(delegate)
        return MethodCall(
            name = list[0].jsonPrimitive.content,
            arguments = list[1].jsonObject,
            clientId = list[2].jsonPrimitive.content,
        )
    }
}

/** RFC 8620 §3.4 — API response envelope */
@Serializable
data class JmapResponse(
    val methodResponses: List<MethodResponse>,
    val sessionState: String,
)

@Serializable(with = MethodResponseSerializer::class)
data class MethodResponse(
    val name: String,
    val result: JsonObject,
    val clientId: String,
)

object MethodResponseSerializer : KSerializer<MethodResponse> {
    private val delegate = ListSerializer(JsonElement.serializer())
    override val descriptor: SerialDescriptor = delegate.descriptor

    override fun serialize(encoder: Encoder, value: MethodResponse) {
        encoder.encodeSerializableValue(
            delegate,
            listOf(JsonPrimitive(value.name), value.result, JsonPrimitive(value.clientId)),
        )
    }

    override fun deserialize(decoder: Decoder): MethodResponse {
        val list = decoder.decodeSerializableValue(delegate)
        return MethodResponse(
            name = list[0].jsonPrimitive.content,
            result = list[1].jsonObject,
            clientId = list[2].jsonPrimitive.content,
        )
    }
}
