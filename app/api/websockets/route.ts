/*
 * TODO:
 *   - separate wordlist table or a special flag field in the Order table
 *   - ping-pong and other event handlers
 */

import { headers as getHeaders } from 'next/headers'
import { NextResponse } from 'next/server'
import { Order, Contract } from '@prisma/client'
import { validate as validateUuid } from 'uuid'
import { WebSocket, WebSocketServer } from 'ws'

import { prisma } from '@/lib/prisma'
import {
    CommandCompletedOrder,
    CommandRemoveOrder,
    CommandInitialData,
    CommandExtraSeed,
    getClientEndpoint
} from '@/lib/websocket'
import {
    validateSeed,
    validateFriendlyAddress,
    validateContract
} from '@/lib/validate'


export async function UPGRADE(ws: WebSocket, wsServer: WebSocketServer) {
    const WS_SECRET = global.env.WEBSOCKET_SECRET

    const clientEndpoint = getClientEndpoint(ws)
    console.log('WEBSOCKET', clientEndpoint, 'new websocket client connection')

    let headers: Headers
    try {
        headers = await getHeaders()
    } catch (err) {
        console.error('WEBSOCKET', clientEndpoint, 'parse headers error:', err)
        ws.terminate()
    }

    const token = headers.get('x-auth-token')
    if (token !== WS_SECRET) {
        console.error('WEBSOCKET', clientEndpoint, 'client failed to provide a valid auth token, terminating connection')
        ws.terminate()
    }

    let orders: Order[]
    try {
        orders = await prisma.order.findMany({
            where: {
                status: 'PROCESSING',
                orderPayments: {
                    every: {
                        type: 'NEW_ORDER',
                        payment: {
                            status: 'completed'
                        }
                    }
                }
            }
        })
    } catch (err) {
        console.error('WEBSOCKET, DATABASE', clientEndpoint, '', err)
        ws.terminate()
    }

    const initialData = CommandInitialData + JSON.stringify({
        orders: orders.map(order => {
            return {
                order_uuid: order.id,
                suffix: order.suffix,
                contract: order.contract,
                case_sensitive: order.caseSensitive,
                timestamp: Math.floor(order.timestamp.getTime() / 1000)
            }
        }),
        wordlist: ['word1', 'word2'] // TODO
    })
    ws.send(initialData, err => {
        if (err) {
            // TODO: handle error
            console.error('WEBSOCKET', clientEndpoint, 'send initial data error:', err)
            ws.terminate()
        }
    })

    ws.once('close', () => {
        console.log('WEBSOCKET', clientEndpoint, 'closing connection')
    })

    ws.on('error', (err) => {
        console.error('WEBSOCKET', clientEndpoint, 'error emitted:', err)
    });

    ws.on('message', async function message(data) {
        const str = data.toString()
        if (str.length < 10) {
            console.error('WEBSOCKET', clientEndpoint, 'received message that is less than 10 characters long, ignoring:', str)
            return
        }
        console.log('WEBSOCKET', clientEndpoint, 'received message:', str)
        const prefix = str.slice(0, 8)
        const jsonString = str.slice(8)
        if (prefix === CommandCompletedOrder) {
            let json: {
                order_uuid: string,
                seed: string,
                address: string
                contract: string
            }
            try {
                json = JSON.parse(jsonString)
            } catch {
                console.error('WEBSOCKET', clientEndpoint, 'invalid json string for CommandCompletedOrder, ignoring:', jsonString)
                return
            }

            const order_uuid = json.order_uuid
            if (!validateUuid(order_uuid)) {
                // TODO
                console.error('WEBSOCKET', clientEndpoint, 'invalid order_uuid, ignoring:', order_uuid)
                return
            }

            const seed = json.seed
            if (!validateSeed(seed)) {
                // TODO
                console.error('WEBSOCKET', clientEndpoint, 'invalid seed, ignoring:', seed)
                return
            }

            const address = json.address
            if (!validateFriendlyAddress(address)) {
                // TODO
                console.error('WEBSOCKET', clientEndpoint, 'invalid address, ignoring:', address)
                return
            }

            const contract = json.contract
            if (!validateContract(contract)) {
                // TODO
                console.error('WEBSOCKET', clientEndpoint, 'invalid contract, ignoring:', contract)
                return
            }

            let order: Order | null = null
            try {
                order = await prisma.order.findFirst({
                    where: {
                        id: order_uuid,
                    },
                    select: {
                        status: true,
                        suffix: true,
                        contract: true
                    }
                })
            } catch (err) {
                // TODO: handle db error
                console.error('WEBSOCKET, DATABASE', clientEndpoint, 'find order error:', err)
                return
            }
            if (!order) {
                // TODO: if a node sends an order that never existed then
                // something probably went wrong
                console.error('WEBSOCKET', clientEndpoint, 'order with given id not found:', order_uuid)
                return
            }

            const accept = order.status === 'PROCESSING' && address.endsWith(order.suffix) && order.contract === contract

            if (accept && order.status !== 'COMPLETED') {
                try {
                    await prisma.order.update({
                        where: {
                            id: order_uuid
                        },
                        data: {
                            status: 'COMPLETED',
                            foundSeed: {
                                create: {
                                    address: address,
                                    seed: seed,
                                    contract: contract
                                }
                            }
                        }
                    })
                } catch (err) {
                    // TODO: handle db error
                    console.error('WEBSOCKET, DATABASE', clientEndpoint, 'update order error:', err)
                    return
                }
            }

            if (accept || order.status === 'COMPLETED') { // TODO: maybe make a new command for orders that have already been completed by other nodes
                const data = CommandRemoveOrder + JSON.stringify({
                    order_uuid: order_uuid
                })
                for (const client of wsServer.clients) {
                    client.send(data, err => {
                        if (err) {
                            // TODO: handle error
                            console.error('WEBSOCKET', clientEndpoint, 'error trying to send CommandRemoveOrder:', err)
                        }
                    })
                }
            }
        } else if (prefix === CommandExtraSeed) {
            let json: {
                seed: string,
                address: string
                contract: string
            }
            try {
                json = JSON.parse(jsonString)
            } catch {
                console.error('WEBSOCKET', clientEndpoint, 'invalid json string for CommandExtraSeed, ignoring:', jsonString)
                return
            }

            const seed = json.seed
            if (!validateSeed(seed)) {
                // TODO
                console.error('WEBSOCKET', clientEndpoint, 'invalid seed, ignoring:', seed)
                return
            }

            const address = json.address
            if (!validateFriendlyAddress(address)) {
                // TODO
                console.error('WEBSOCKET', clientEndpoint, 'invalid address, ignoring:', address)
                return
            }

            const contract = json.contract
            if (!validateContract(contract)) {
                // TODO
                console.error('WEBSOCKET', clientEndpoint, 'invalid contract, ignoring:', contract)
                return
            }

            try {
                await prisma.foundSeed.create({
                    data: {
                        address: address,
                        seed: seed,
                        contract: contract
                    }
                })
            } catch (err) {
                // TODO: handle db error
                console.error('WEBSOCKET, DATABASE', clientEndpoint, 'create extra seed error:', err)
                return
            }
        } else {
            console.error('WEBSOCKET', clientEndpoint, 'received an unknown command, ignoring:', str)
        }
    });

    // ws.on("ping", function ping() {})                               // TODO
    // ws.on("pong", function pong() {})                               // TODO
    // ws.on("redirect", function redirect() {})                       // TODO
    // ws.on("unexpected-response", function unexpectedResponse() {}) // TODO

    global.wsServer = wsServer
}

/*
 * The HTTP 426 Upgrade Required client error response status code indicates
 * that the server refused to perform the request using the current protocol
 * but might be willing to do so after the client upgrades to a different protocol.
 * The server sends an Upgrade header with this response to indicate the
 * required protocol(s).
 *
 * https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/426
 */
export function GET() {
    const headers = new Headers();
    headers.set('Connection', 'Upgrade');
    headers.set('Upgrade', 'websocket');
    return new Response('Upgrade Required', { status: 426, headers });
}
