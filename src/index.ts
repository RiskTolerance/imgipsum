import { Hono } from 'hono'
import { HTTPException } from 'hono/http-exception'
import { env } from 'cloudflare:workers'
import * as z from 'zod'

const app = new Hono<{ Bindings: Env }>()

// const enums
const SIZES = new Set([100, 200, 400, 800, 1200, 1600])
const COUNTS: Record<string, number> = {
  portraits: 20,
  // groups: 20,
  food: 20,
  landscapes: 20,
  architecture: 20,
  // interiors: 20,
  // abstract: 20,
  // travel: 20,
}

const Request = z.object({
  format: z.enum(['webp', 'avif', 'jpeg', 'png']),
  w: z.string().regex(/^\d+$/).refine(s => SIZES.has(+s), { error: 'invalid size' }),
  h: z.string().regex(/^\d+$/).refine(s => SIZES.has(+s), { error: 'invalid size' }),
  rest: z.string().min(1).refine(s => !s.includes('..'), { error: 'no traversal' }).refine(s => !s.startsWith('/'), { error: 'no absolute' }),
})

type RequestParams = z.infer<typeof Request>
type Format = RequestParams['format']
type FormatString = `image/${Format}`

app.use('*', async (c, next) => {
  const ip = c.req.header('cf-connecting-ip') ?? 'unknown'
  if (ip) {
    const { success } = await c.env.RATE_LIMITER.limit({ key: ip })
    if (!success) throw new HTTPException(429, { message: 'rate limited' })
  }
  await next()
})

app.get('/one/:w/:h/:format/:rest{.+}', async (c) => {
  const cache = caches.default
  const cached = await cache.match(c.req.raw)
  if (cached) return cached

  const params = c.req.param()
  const parse = Request.safeParse(params)
  if (!parse.success) {
    throw new HTTPException(400, {
      message: 'Input params do not match expected shape! See docs at https://www.docs.com'
    })
  }
  const { rest, format, w, h } = params

  const obj = await env.CF_BUCKET.get(`${rest}.jpg`).then(r => {
    if (r === null || r === undefined) {
      throw new HTTPException(400, {
        message: 'Image does not exist!'
      })
    }
    return r
  })
  const formatString = `image/${format}` as FormatString
  const transform = (await env.CF_IMAGES.input(obj.body).transform({ width: +w, height: +h }).output({ format: formatString })).response()
  const res = new Response(transform.body, {
    headers: {
      'Content-Type': transform.headers.get('Content-Type') ?? formatString,
      'Cache-Control': 'public, max-age=31536000, immutable'
    }
  })
  c.executionCtx.waitUntil(cache.put(c.req.raw, res.clone()))
  return res
})

app.get('/random/:w/:h/:format/:rest{.+}', (c) => {
  const params = c.req.param()
  const parse = Request.safeParse(params)
  if (!parse.success) {
    throw new HTTPException(400, {
      message: 'Input params do not match expected shape! See docs at https://www.docs.com'
    })
  }
  const { rest, format, w, h } = params

  const count = COUNTS[rest]
  if (!count) {
    throw new HTTPException(404, { message: 'invalid collection' })
  }
  const random = Math.floor(Math.random() * count) + 1

  return c.redirect(`/one/${w}/${h}/${format}/${rest}/${random}`, 302)
})

export default app
