"""Applies the fire pass to an ExCamera tree (CRLF kept). Usage: python apply_fire.py <tree> <fire_shader.glsl>"""
import sys
from pathlib import Path

tree, shader_path = Path(sys.argv[1]), Path(sys.argv[2])


def edit(rel, pairs):
    p = tree / rel
    s = p.read_bytes().decode('utf-8').replace('\r\n', '\n')
    for old, new in pairs:
        if s.count(old) != 1:
            raise SystemExit(f'{rel}: expected one match for {old[:70]!r}, found {s.count(old)}')
        s = s.replace(old, new)
    p.write_bytes(s.replace('\n', '\r\n').encode('utf-8'))


shader = shader_path.read_text(encoding='utf-8').rstrip('\n')
comment = []
body = []
for line in shader.split('\n'):
    (comment if not body and line.startswith('//') else body).append(line)
fire_shader = '\n'.join(comment) + '\nstatic const char* const fireShader = R"glsl(\n' + '\n'.join(body) + '\n)glsl";\n'

PASS = '''                woundTextureBarrier(); // the finishing pass reads what was just written
                g.bindVertexArray(r.viewVao);
            }
        }
        // Fire and smoke (fire.inl) next, on the same image, only inside the box that holds every volume.
        if (finishMode && request.fires.count && r.fireProgram && g.uniform4fv && projection.worldUpValid &&
            (source == r.viewColor || source == r.chainTex) && woundPassReady(g, r) && prepareHeldNoise(g, r)) {
            const FireUniforms& fires = request.fires;
            // Each volume's bounding sphere, as the shader builds it; a volume the camera stands in covers the view.
            float box[4] = {1.f, 1.f, 0.f, 0.f};
            for (unsigned k = 0; k < fires.count; ++k) {
                const float* a = fires.a[k];
                const float* b = fires.b[k];
                const float height = std::sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2]);
                if (!(height >= 1.f)) continue;
                const float plume = b[3] < 0.5f && fires.smoke > 0.5f ? 3.2f : 1.f + 0.6f * fires.c[k][2] * fires.smoke;
                const float top = height * plume, reach = top * 0.5f + a[3] * (1.f + 0.9f * (plume - 1.f));
                const float c[3] = {a[0] + b[0] / height * top * 0.5f, a[1] + b[1] / height * top * 0.5f, a[2] + b[2] / height * top * 0.5f};
                const float depth = -c[2];
                if (!(depth - reach > 1.f)) { box[0] = box[1] = 0.f; box[2] = box[3] = 1.f; break; }
                const float sx = (projection.p0 * c[0] / depth - projection.p8) * 0.5f + 0.5f;
                const float sy = (projection.p5 * c[1] / depth - projection.p9) * 0.5f + 0.5f;
                const float rx = std::abs(projection.p0) * reach / (depth - reach) * 0.5f;
                const float ry = std::abs(projection.p5) * reach / (depth - reach) * 0.5f;
                box[0] = (std::min)(box[0], sx - rx); box[1] = (std::min)(box[1], sy - ry);
                box[2] = (std::max)(box[2], sx + rx); box[3] = (std::max)(box[3], sy + ry);
            }
            box[0] = std::clamp(box[0], 0.f, 1.f); box[1] = std::clamp(box[1], 0.f, 1.f);
            box[2] = std::clamp(box[2], 0.f, 1.f); box[3] = std::clamp(box[3], 0.f, 1.f);
            if (box[2] > box[0] && box[3] > box[1]) {
                const auto& u = viewUniforms[contextIndex][programFire];
                g.activeTexture(glc::texture0 + heldNoiseUnit);
                noiseTouched = true;
                g.bindTexture(texture3D, r.heldNoise);
                g.activeTexture(glc::texture1);
                g.bindTexture(GL_TEXTURE_2D, r.viewDepth);
                g.activeTexture(glc::texture0);
                g.bindTexture(GL_TEXTURE_2D, source);
                g.bindFramebuffer(glc::framebuffer, r.woundFbo);
                g.framebufferTexture2D(glc::framebuffer, glc::colorAttachment0, GL_TEXTURE_2D, source, 0);
                setViewport(g, 0, 0, viewport[2], viewport[3]);
                glDisable(GL_BLEND);
                g.useProgram(r.fireProgram);
                setViewUniforms(g, u, frame);
                g.uniform1i(u.at[uFireNoise], GLint(heldNoiseUnit));
                g.uniform1f(u.at[uFireCount], float(fires.count));
                g.uniform4fv(u.at[uFireA], GLsizei(fires.count), &fires.a[0][0]);
                g.uniform4fv(u.at[uFireB], GLsizei(fires.count), &fires.b[0][0]);
                g.uniform4fv(u.at[uFireC], GLsizei(fires.count), &fires.c[0][0]);
                g.uniform4f(u.at[uFireRect], box[0], box[1], box[2], box[3]);
                // Seconds, wrapped every 1000 s so the float keeps its precision.
                g.uniform4f(u.at[uFireLook], float(now % 1000000ull) / 1000.f, fires.steps, fires.smoke, 0.f);
                g.uniform4f(u.at[uFireRight], fires.right[0], fires.right[1], fires.right[2], 0.f);
                g.uniform1f(u.at[uFrameOffset], float(frameIndex % 64u));
                const float quad[8] = {box[0] * 2.f - 1.f, box[1] * 2.f - 1.f, box[2] * 2.f - 1.f, box[1] * 2.f - 1.f,
                                       box[0] * 2.f - 1.f, box[3] * 2.f - 1.f, box[2] * 2.f - 1.f, box[3] * 2.f - 1.f};
                g.bindVertexArray(r.woundQuadVao);
                g.bindBuffer(glc::arrayBuffer, r.woundQuadVbo);
                g.bufferData(glc::arrayBuffer, ptrdiff_t(sizeof quad), quad, glc::dynamicDraw);
                g.vertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8, nullptr);
                g.enableVertexAttribArray(0);
                woundTextureBarrier();
                glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
                woundTextureBarrier(); // the finishing pass reads what was just written
                g.bindVertexArray(r.viewVao);
            }
        }
        if (finishMode) {
            beginPass(true);'''

edit('src/mod/view_effects.inl', [
    ('''void main() {
    vec4 c = texture2D(sceneTex, uv);
    gl_FragColor = vec4(woundMarks(c.rgb), c.a);
}
)glsl";
''', '''void main() {
    vec4 c = texture2D(sceneTex, uv);
    gl_FragColor = vec4(woundMarks(c.rgb), c.a);
}
)glsl";

''' + fire_shader),
    ('''    uWoundA, uWoundB, uWoundC, uWoundCount, uWoundRect, uDripA, uDripCount, viewUniformCount''',
     '''    uWoundA, uWoundB, uWoundC, uWoundCount, uWoundRect, uDripA, uDripCount,
    uFireA, uFireB, uFireC, uFireCount, uFireRect, uFireLook, uFireRight, uFireNoise, viewUniformCount'''),
    ('''    "woundA", "woundB", "woundC", "woundCount", "woundRect", "dripA", "dripCount"};''',
     '''    "woundA", "woundB", "woundC", "woundCount", "woundRect", "dripA", "dripCount",
    "fireA", "fireB", "fireC", "fireCount", "fireRect", "fireLook", "fireRight", "fireNoise"};'''),
    ('''    programMeter, programDistance, programWounds, programCount''',
     '''    programMeter, programDistance, programWounds, programFire, programCount'''),
    ('''    viewDistanceFailed = 4096, viewWoundsFailed = 8192''',
     '''    viewDistanceFailed = 4096, viewWoundsFailed = 8192, viewFireFailed = 16384'''),
    ('''    WoundUniforms wounds;                // wounds in view, already in this view's space
    bool finish() const {
        return smooth > 0.f || sharpen > 0.f || visor > 0.f || ghost || detail > 0.f || level > 0.f || hurt > 0.f || winded > 0.f ||
               wounds.any();''',
     '''    WoundUniforms wounds;                // wounds in view, already in this view's space
    FireUniforms fires;                  // fire and smoke volumes in view (fire.inl), this view's space
    bool finish() const {
        return smooth > 0.f || sharpen > 0.f || visor > 0.f || ghost || detail > 0.f || level > 0.f || hurt > 0.f || winded > 0.f ||
               wounds.any() || fires.any();'''),
    ('''            owner->meterAttempted = owner->distanceAttempted = owner->woundAttempted = false;''',
     '''            owner->meterAttempted = owner->distanceAttempted = owner->woundAttempted = owner->fireAttempted = false;'''),
    ('''         viewWoundsFailed, "wound marks"}};''',
     '''         viewWoundsFailed, "wound marks"},
        {float(finishMode && request.fires.count), &r.fireProgram, &owner->fireAttempted, nullptr, fireShader,
         viewFireFailed, "fire and smoke"}};'''),
    ('''                woundTextureBarrier(); // the finishing pass reads what was just written
                g.bindVertexArray(r.viewVao);
            }
        }
        if (finishMode) {
            beginPass(true);''', PASS),
    ('''        if (readViewMatrices(view, matrices)) woundViewUniforms(matrices.view, request.wounds);
    }
''', '''        if (readViewMatrices(view, matrices)) woundViewUniforms(matrices.view, request.wounds);
    }
    // Fire and smoke: desktop and VR eyes alike, like the wounds.
    if (fireLook.load(std::memory_order_relaxed) > 0.f) {
        ViewEffectProjectionSnapshot matrices;
        if (readViewMatrices(view, matrices) && matrices.worldUpValid)
            fireViewUniforms(matrices.view, viewCpuFrameMs.load(std::memory_order_relaxed), request.fires);
    }
'''),
])
edit('src/mod/overlay.inl', [
    ('''         meterAttempted = false, distanceAttempted = false, woundAttempted = false;''',
     '''         meterAttempted = false, distanceAttempted = false, woundAttempted = false, fireAttempted = false;'''),
])
edit('src/cue_resources.h', [
    ('''    unsigned woundProgram = 0, woundFbo = 0, woundQuadVao = 0, woundQuadVbo = 0;''',
     '''    unsigned woundProgram = 0, woundFbo = 0, woundQuadVao = 0, woundQuadVbo = 0;
    // Fire and smoke (fire.inl): its program; it draws through the wound pass's framebuffer and quad.
    unsigned fireProgram = 0;'''),
    ('''finishProgram || woundProgram || woundFbo ||''', '''finishProgram || woundProgram || fireProgram || woundFbo ||'''),
    ('''        retireProgram(g, woundProgram);''', '''        retireProgram(g, woundProgram);
        retireProgram(g, fireProgram);'''),
])
edit('src/mod/session.inl', [
    ('''    j.fixed("level_detail_scale", levelDetailScale.load(std::memory_order_relaxed), 2);''',
     '''    j.fixed("level_detail_scale", levelDetailScale.load(std::memory_order_relaxed), 2);
    j.fixed("fire_volumes", float(fireShown.load(std::memory_order_relaxed)), 0);
    j.fixed("fire_quality", fireQuality.load(std::memory_order_relaxed), 2);
    j.fixed("fire_faults", float(fireFaults.load(std::memory_order_relaxed)), 0);'''),
])
edit('src/first_person.cpp', [
    ('''#include "mod/wounds.inl"''', '''#include "mod/wounds.inl"
#include "mod/fire.inl"'''),
])
fire = tree / 'src/mod/fire.inl'
fire.write_bytes(fire.read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
print('FIRE_PASS_APPLIED')
