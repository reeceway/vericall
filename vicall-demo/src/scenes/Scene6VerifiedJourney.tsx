import React from 'react';
import {AbsoluteFill, Img, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {PhoneMockup} from '../components/PhoneMockup';
import {RevealLines} from '../components/RevealLines';
import {SceneContainer} from '../components/SceneContainer';
import {staticAsset} from '../lib/static';
import {colors, fonts} from '../theme';

const ramp = (frame: number, start: number, end: number, from: number, to: number) =>
	interpolate(frame, [start, end], [from, to], {
		extrapolateLeft: 'clamp',
		extrapolateRight: 'clamp',
	});

export const Scene6VerifiedJourney: React.FC<{durationInFrames?: number}> = ({durationInFrames}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const incomingAsset = staticAsset('clips/iphone-callkit-incoming.png');
	const safeAsset = staticAsset('clips/iphone-call-safe.png');
	const sceneDuration = durationInFrames ?? 390;
	const incomingEnd = Math.round(sceneDuration * 0.44);
	const transitionFrames = 20;
	const swapMix = ramp(frame, incomingEnd - transitionFrames, incomingEnd + transitionFrames, 0, 1);
	const enter = spring({
		fps,
		frame: Math.max(0, frame - 4),
		config: {damping: 18, stiffness: 112},
		durationInFrames: 28,
	});
	const settle = spring({
		fps,
		frame: Math.max(0, frame - 28),
		config: {damping: 20, stiffness: 90},
		durationInFrames: 34,
	});
	const scenePivot = ramp(frame, incomingEnd - 18, incomingEnd + 22, 0, 1);
	const phoneScale =
		interpolate(enter, [0, 1], [0.89, 1]) *
		interpolate(settle, [0, 1], [1, 1.004]) *
		interpolate(scenePivot, [0, 1], [1, 1.01]);
	const phoneX =
		interpolate(enter, [0, 1], [132, 0]) +
		interpolate(settle, [0, 1], [0, -8]) +
		interpolate(scenePivot, [0, 1], [0, -14]);
	const phoneY =
		interpolate(enter, [0, 1], [22, 0]) +
		interpolate(settle, [0, 1], [0, -6]) +
		interpolate(scenePivot, [0, 1], [0, -10]);
	const phoneRotateY =
		interpolate(enter, [0, 1], [-18, -7]) +
		interpolate(settle, [0, 1], [0, 1.5]) +
		interpolate(scenePivot, [0, 1], [0, 6]);
	const phoneRotateZ =
		interpolate(enter, [0, 1], [5.5, 1.0]) +
		interpolate(settle, [0, 1], [0, -0.5]) +
		interpolate(scenePivot, [0, 1], [0, -0.8]);
	const phoneRotateX =
		interpolate(enter, [0, 1], [7, 2.8]) +
		interpolate(settle, [0, 1], [0, -0.25]) +
		interpolate(scenePivot, [0, 1], [0, 1.2]);
	const flipRotateY =
		swapMix < 0.5
			? interpolate(swapMix, [0, 0.5], [0, 76])
			: interpolate(swapMix, [0.5, 1], [-76, 0]);
	const visibleAsset = swapMix < 0.5 ? incomingAsset : safeAsset;
	const screenBlur = interpolate(Math.abs(flipRotateY), [0, 76], [0, 1.4]);

	return (
		<SceneContainer
			durationInFrames={durationInFrames}
			background="linear-gradient(180deg, #fcfdff 0%, #f2f6fd 100%)"
		>
			<AbsoluteFill style={{overflow: 'hidden'}}>
				<div
					style={{
						position: 'absolute',
						inset: 0,
						background:
							'radial-gradient(circle at 0% 100%, rgba(77,124,255,0.03) 0%, rgba(77,124,255,0) 32%), radial-gradient(circle at 100% 0%, rgba(0,230,118,0.026) 0%, rgba(0,230,118,0) 26%)',
					}}
				/>

				<div
					style={{
						position: 'absolute',
						left: 98,
						top: 118,
						maxWidth: 520,
						opacity: enter,
						transform: `translateY(${interpolate(enter, [0, 1], [20, 0])}px)`,
					}}
				>
					<RevealLines
						lines={[{text: 'APP CLOSED'}]}
						frame={frame}
						fps={fps}
						blur={8}
						translateY={14}
						containerStyle={{marginBottom: 16}}
						lineStyle={{
							fontFamily: fonts.body,
							fontSize: 18,
							letterSpacing: 2.4,
							textTransform: 'uppercase',
							color: colors.accent,
							fontWeight: 700,
						}}
					/>
					<RevealLines
						lines={[
							{text: 'Normal iPhone CallKit'},
							{text: 'when Vicall is closed.'},
						]}
						frame={frame}
						fps={fps}
						startFrame={2}
						staggerFrames={4}
						gap={2}
						blur={14}
						translateY={22}
						containerStyle={{marginBottom: 22, maxWidth: 520}}
						lineStyle={{
							fontFamily: fonts.headline,
							fontSize: 56,
							fontWeight: 800,
							lineHeight: 1.02,
							color: colors.ink,
						}}
					/>
					<RevealLines
						lines={[
							{text: 'If the voice sounds safe,'},
							{text: 'the call keeps going quietly.'},
							{text: 'No extra alert interrupts the user.'},
						]}
						frame={frame}
						fps={fps}
						startFrame={10}
						staggerFrames={3}
						gap={2}
						blur={10}
						translateY={16}
						containerStyle={{marginBottom: 28, maxWidth: 450}}
						lineStyle={{
							fontFamily: fonts.body,
							fontSize: 26,
							lineHeight: 1.38,
							color: colors.inkMuted,
						}}
					/>
					<div
						style={{
							display: 'inline-flex',
							alignItems: 'center',
							gap: 12,
						}}
					>
						<div
							style={{
								width: 34,
								height: 2,
								borderRadius: 2,
								background: colors.safe,
								flexShrink: 0,
							}}
						/>
						<div
							style={{
								fontFamily: fonts.body,
								fontSize: 22,
								fontWeight: 600,
								color: colors.ink,
							}}
						>
							Safe calls stay quiet with no extra alert.
						</div>
					</div>
				</div>

				<div
					style={{
						position: 'absolute',
						right: 126,
						top: 112,
						bottom: 88,
						display: 'flex',
						alignItems: 'center',
						justifyContent: 'center',
						perspective: 1800,
						opacity: enter,
						transform: `translateX(${phoneX}px) translateY(${phoneY}px) scale(${phoneScale}) rotateX(${phoneRotateX}deg) rotateY(${phoneRotateY + flipRotateY}deg) rotateZ(${phoneRotateZ}deg)`,
					}}
				>
					<PhoneMockup
						glowIntensity={0}
						glassOverlayOpacity={0.42}
						angledReflectionOpacity={0.18}
						topReflectionOpacity={0.24}
						shadowStrength={1.26}
						scale={1.03}
					>
						<AbsoluteFill style={{background: '#000'}}>
							{visibleAsset ? (
								<Img
									src={visibleAsset}
									style={{
										width: '100%',
										height: '100%',
										objectFit: 'cover',
										filter: `blur(${screenBlur}px)`,
									}}
								/>
							) : null}
						</AbsoluteFill>
					</PhoneMockup>
				</div>
			</AbsoluteFill>
		</SceneContainer>
	);
};
