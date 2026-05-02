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

export const Scene7CloneJourney: React.FC<{durationInFrames?: number}> = ({durationInFrames}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const openWarningAsset = staticAsset('clips/sim-call-red-chip.png');
	const unsureAsset = staticAsset('clips/iphone-call-unsure.png');
	const redAsset = staticAsset('clips/iphone-call-red.png');
	const sceneDuration = durationInFrames ?? 450;
	const openToClosed = Math.round(sceneDuration * 0.34);
	const cautionToRed = Math.round(sceneDuration * 0.68);
	const transitionFrames = 18;
	const enter = spring({
		fps,
		frame: Math.max(0, frame - 4),
		config: {damping: 18, stiffness: 112},
		durationInFrames: 28,
	});
	const settle = spring({
		fps,
		frame: Math.max(0, frame - 30),
		config: {damping: 20, stiffness: 88},
		durationInFrames: 34,
	});
	const openToClosedMix = ramp(frame, openToClosed - transitionFrames, openToClosed + transitionFrames, 0, 1);
	const cautionToRedMix = ramp(frame, cautionToRed - transitionFrames, cautionToRed + transitionFrames, 0, 1);
	const phoneScale =
		interpolate(enter, [0, 1], [0.9, 1]) *
		interpolate(settle, [0, 1], [1, 1.004]) *
		interpolate(openToClosedMix, [0, 1], [1, 1.01]) *
		interpolate(cautionToRedMix, [0, 1], [1, 1.008]);
	const phoneX =
		interpolate(enter, [0, 1], [132, 0]) +
		interpolate(settle, [0, 1], [0, -8]) +
		interpolate(openToClosedMix, [0, 1], [0, -12]) +
		interpolate(cautionToRedMix, [0, 1], [0, -10]);
	const phoneY =
		interpolate(enter, [0, 1], [24, 0]) +
		interpolate(settle, [0, 1], [0, -8]) +
		interpolate(openToClosedMix, [0, 1], [0, -8]) +
		interpolate(cautionToRedMix, [0, 1], [0, -6]);
	const phoneRotateY =
		interpolate(enter, [0, 1], [-18, -7]) +
		interpolate(settle, [0, 1], [0, 2.4]) +
		interpolate(openToClosedMix, [0, 1], [0, 7]) +
		interpolate(cautionToRedMix, [0, 1], [0, -1.2]);
	const phoneRotateZ =
		interpolate(enter, [0, 1], [6, 1.2]) +
		interpolate(settle, [0, 1], [0, -0.8]) +
		interpolate(openToClosedMix, [0, 1], [0, -1.0]) +
		interpolate(cautionToRedMix, [0, 1], [0, 0.5]);
	const phoneRotateX =
		interpolate(enter, [0, 1], [8, 3]) +
		interpolate(settle, [0, 1], [0, -0.3]) +
		interpolate(openToClosedMix, [0, 1], [0, 1.0]) +
		interpolate(cautionToRedMix, [0, 1], [0, 0.8]);

	const firstFlipRotate =
		openToClosedMix < 0.5
			? interpolate(openToClosedMix, [0, 0.5], [0, 78])
			: interpolate(openToClosedMix, [0.5, 1], [-78, 0]);
	const secondFlipRotate =
		cautionToRedMix < 0.5
			? interpolate(cautionToRedMix, [0, 0.5], [0, -82])
			: interpolate(cautionToRedMix, [0.5, 1], [82, 0]);
	const currentAsset =
		openToClosedMix < 0.5 ? openWarningAsset : cautionToRedMix < 0.5 ? unsureAsset : redAsset;
	const screenBlur = interpolate(
		Math.max(Math.abs(firstFlipRotate), Math.abs(secondFlipRotate)),
		[0, 82],
		[0, 1.5]
	);

	return (
		<SceneContainer
			durationInFrames={durationInFrames}
			background="linear-gradient(180deg, #fcfdff 0%, #f3f7fd 100%)"
		>
			<AbsoluteFill style={{overflow: 'hidden', background: 'linear-gradient(180deg, #fcfdff 0%, #f3f7fd 100%)'}}>
				<div
					style={{
						position: 'absolute',
						inset: 0,
						background:
							'radial-gradient(circle at 0% 100%, rgba(77,124,255,0.028) 0%, rgba(77,124,255,0) 32%), radial-gradient(circle at 100% 0%, rgba(255,59,59,0.03) 0%, rgba(255,59,59,0) 26%)',
					}}
				/>

				<div
					style={{
						position: 'absolute',
						left: 98,
						top: 112,
						maxWidth: 490,
						zIndex: 3,
						opacity: enter,
						transform: `translateY(${interpolate(enter, [0, 1], [20, 0])}px)`,
					}}
				>
					<RevealLines
						lines={[{text: 'VOICE CLONE DETECTION'}]}
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
							color: colors.danger,
							fontWeight: 700,
						}}
					/>
					<RevealLines
						lines={[
							{text: 'Vicall warns'},
							{text: 'inside the app.'},
							{text: 'If the app is closed,'},
							{text: 'the device throws the alert.'},
						]}
						frame={frame}
						fps={fps}
						startFrame={3}
						staggerFrames={4}
						gap={2}
						blur={14}
						translateY={22}
						containerStyle={{marginBottom: 18, maxWidth: 440}}
						lineStyle={{
							fontFamily: fonts.headline,
							fontSize: 46,
							fontWeight: 800,
							lineHeight: 1.03,
							color: colors.ink,
						}}
					/>
					<RevealLines
						lines={[
							{text: 'App open shows the warning first.'},
							{text: 'If Vicall is closed, the iPhone'},
							{text: 'delivers the alert and vibration.'},
						]}
						frame={frame}
						fps={fps}
						startFrame={12}
						staggerFrames={3}
						gap={2}
						blur={10}
						translateY={16}
						containerStyle={{marginBottom: 24, maxWidth: 400}}
						lineStyle={{
							fontFamily: fonts.body,
							fontSize: 23,
							lineHeight: 1.34,
							color: colors.inkMuted,
						}}
					/>
					<div style={{display: 'flex', flexDirection: 'column', gap: 12, maxWidth: 360}}>
						{[
							{text: 'App open = in-call warning', tone: colors.danger},
							{text: 'App closed = device alert', tone: colors.accent},
						].map((note, index) => {
							const noteEnter = spring({
								fps,
								frame: Math.max(0, frame - 12 - index * 5),
								config: {damping: 18, stiffness: 126},
								durationInFrames: 20,
							});

							return (
								<div
									key={note.text}
									style={{
										display: 'inline-flex',
										alignItems: 'center',
										gap: 10,
										opacity: noteEnter,
										transform: `translateY(${interpolate(noteEnter, [0, 1], [10, 0])}px)`,
										filter: `blur(${interpolate(noteEnter, [0, 1], [6, 0])}px)`,
									}}
								>
									<div
										style={{
											width: 34,
											height: 2,
											borderRadius: 2,
											background: note.tone,
										}}
									/>
									<div
										style={{
											fontFamily: fonts.body,
											fontSize: 20,
											fontWeight: 600,
											color: colors.ink,
										}}
									>
										{note.text}
									</div>
								</div>
							);
						})}
					</div>
				</div>

				<div
					style={{
						position: 'absolute',
						right: 126,
						top: 110,
						bottom: 88,
						display: 'flex',
						alignItems: 'center',
						justifyContent: 'center',
						perspective: 1800,
						opacity: enter,
						transform: `translateX(${phoneX}px) translateY(${phoneY}px) scale(${phoneScale}) rotateX(${phoneRotateX}deg) rotateY(${phoneRotateY + firstFlipRotate + secondFlipRotate}deg) rotateZ(${phoneRotateZ}deg)`,
					}}
				>
					<PhoneMockup
						glowIntensity={0}
						glassOverlayOpacity={0.4}
						angledReflectionOpacity={0.16}
						topReflectionOpacity={0.22}
						shadowStrength={1.26}
						scale={1.02}
					>
						<AbsoluteFill style={{background: '#000'}}>
							{currentAsset ? (
								<Img
									src={currentAsset}
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
