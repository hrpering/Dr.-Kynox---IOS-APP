import {AbsoluteFill, Composition, Sequence, spring, useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import React from 'react';

const BrandScene: React.FC<{long?: boolean}> = ({long = false}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const scale = spring({frame, fps, config: {damping: 12}});
  const glow = interpolate(frame, [0, 45, 90], [0.2, 0.9, 0.35], {extrapolateRight: 'clamp'});
  const subtitleOpacity = interpolate(frame, [8, 24, 52], [0, 1, 1], {extrapolateRight: 'clamp'});
  const stepOpacity = (from: number, to: number) =>
    interpolate(frame, [from, from + 12, to], [0, 1, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  return (
    <AbsoluteFill
      style={{
        background: 'radial-gradient(circle at 50% 20%, #eaf2ff, #f8fafc 45%, #eef3ff 100%)',
        justifyContent: 'center',
        alignItems: 'center',
        fontFamily: 'SF Pro Display, Inter, sans-serif',
      }}
    >
      <div
        style={{
          width: long ? 680 : 540,
          height: long ? 380 : 310,
          borderRadius: 34,
          border: '1px solid #d6e4ff',
          background: 'linear-gradient(160deg, #1d6fe8 0%, #1452b8 100%)',
          boxShadow: `0 18px 80px rgba(29,111,232,${glow})`,
          display: 'grid',
          placeItems: 'center',
          transform: `scale(${0.95 + scale * 0.05})`,
          position: 'relative',
          overflow: 'hidden',
        }}
      >
        <div style={{color: '#fff', fontSize: long ? 72 : 56, fontWeight: 700}}>Dr.Kynox</div>
        <div
          style={{
            position: 'absolute',
            bottom: 34,
            left: 34,
            right: 34,
            opacity: subtitleOpacity,
            color: 'rgba(255,255,255,0.92)',
            fontSize: long ? 30 : 24,
            fontWeight: 500,
            letterSpacing: 0.2,
          }}
        >
          Klinik vaka simülasyonu
        </div>
      </div>
      {long ? (
        <div
          style={{
            marginTop: 26,
            width: 680,
            display: 'grid',
            gap: 12,
          }}
        >
          {[
            {title: '1. Bölüm seç', detail: 'Enfeksiyon, kardiyoloji, nöroloji...'},
            {title: '2. Zorluk seç', detail: 'Kolay, orta veya zor akış'},
            {title: '3. Modu başlat', detail: 'Sesli ya da yazılı vaka görüşmesi'},
          ].map((step, idx) => (
            <div
              key={step.title}
              style={{
                border: '1px solid #dbe7ff',
                borderRadius: 16,
                background: '#ffffff',
                padding: '14px 18px',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                opacity: stepOpacity(32 + idx * 18, 170),
                transform: `translateY(${Math.max(0, 16 - frame * 0.08)}px)`,
              }}
            >
              <div style={{fontSize: 24, color: '#0f172a', fontWeight: 650}}>{step.title}</div>
              <div style={{fontSize: 20, color: '#475569', fontWeight: 500}}>{step.detail}</div>
            </div>
          ))}
        </div>
      ) : (
        <div
          style={{
            marginTop: 24,
            color: '#0f172a',
            fontSize: 30,
            fontWeight: 600,
            opacity: subtitleOpacity,
          }}
        >
          Sesli ve yazılı vaka pratiği
        </div>
      )}
    </AbsoluteFill>
  );
};

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition id="IntroShort" component={() => <BrandScene long={false} />} durationInFrames={90} fps={30} width={1080} height={1080} />
      <Composition id="IntroLong" component={() => <BrandScene long={true} />} durationInFrames={180} fps={30} width={1080} height={1080} />
    </>
  );
};

export default RemotionRoot;
