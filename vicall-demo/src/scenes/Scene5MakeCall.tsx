import React from 'react';
import {AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {PhoneMockup} from '../components/PhoneMockup';
import {RevealLines} from '../components/RevealLines';
import {SceneContainer} from '../components/SceneContainer';
import {colors, fonts} from '../theme';

const notes = [
	{text: 'App open uses the Vicall in-call UI.', tone: colors.safe},
	{text: 'Safe calls stay calm and readable.', tone: colors.accent},
];

export const Scene5MakeCall: React.FC<{durationInFrames?: number}> = ({durationInFrames}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const enter = spring({fps, frame, config: {damping: 18, stiffness: 118}, durationInFrames: 24});
	const phoneEnter = spring({
		fps,
		frame: Math.max(0, frame - 4),
		config: {damping: 18, stiffness: 112},
		durationInFrames: 28,
	});
	const phoneSettle = spring({
		fps,
		frame: Math.max(0, frame - 30),
		config: {damping: 18, stiffness: 88},
		durationInFrames: 34,
	});
	const phoneScale =
		interpolate(phoneEnter, [0, 1], [0.92, 1.01]) * interpolate(phoneSettle, [0, 1], [1, 1.003]);
	const phoneX =
		interpolate(phoneEnter, [0, 1], [132, 0]) + interpolate(phoneSettle, [0, 1], [0, -8]);
	const phoneY =
		interpolate(phoneEnter, [0, 1], [28, 0]) + interpolate(phoneSettle, [0, 1], [0, -5]);
	const phoneRotateY =
		interpolate(phoneEnter, [0, 1], [-24, -10]) + interpolate(phoneSettle, [0, 1], [0, 3.2]);
	const phoneRotateZ =
		interpolate(phoneEnter, [0, 1], [9, 1.1]) + interpolate(phoneSettle, [0, 1], [0, -0.5]);
	const phoneRotateX =
		interpolate(phoneEnter, [0, 1], [8, 3.4]) + interpolate(phoneSettle, [0, 1], [0, -0.4]);

	return (
		<SceneContainer
			durationInFrames={durationInFrames}
			background="linear-gradient(180deg, #fbfcff 0%, #f3f7fd 100%)"
		>
			<AbsoluteFill style={{overflow: 'hidden'}}>
				<div
					style={{
						position: 'absolute',
						inset: 0,
						background:
							'radial-gradient(circle at 0% 0%, rgba(77,124,255,0.032) 0%, rgba(77,124,255,0) 30%), radial-gradient(circle at 100% 100%, rgba(77,124,255,0.018) 0%, rgba(77,124,255,0) 34%)',
					}}
				/>

				<div
					style={{
						position: 'absolute',
						left: 92,
						top: 118,
						maxWidth: 580,
						opacity: enter,
						transform: `translateY(${interpolate(enter, [0, 1], [22, 0])}px)`,
					}}
				>
					<RevealLines
						lines={[{text: 'APP OPEN'}]}
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
							color: colors.safe,
							fontWeight: 700,
						}}
					/>
					<RevealLines
						lines={[
							{text: 'Vicall shows'},
							{text: 'its own call UI'},
							{text: 'while detection runs.'},
						]}
						frame={frame}
						fps={fps}
						startFrame={3}
						staggerFrames={4}
						gap={2}
						blur={14}
						translateY={22}
						containerStyle={{marginBottom: 22, maxWidth: 560}}
						lineStyle={{
							fontFamily: fonts.headline,
							fontWeight: 800,
							fontSize: 60,
							lineHeight: 1.01,
							color: colors.ink,
						}}
					/>
					<RevealLines
						lines={[
							{text: 'When the app is open, the trust signal'},
							{text: 'stays inside the call screen.'},
							{text: 'The user keeps talking unless'},
							{text: 'the call needs attention.'},
						]}
						frame={frame}
						fps={fps}
						startFrame={11}
						staggerFrames={3}
						gap={2}
						blur={10}
						translateY={16}
						containerStyle={{marginBottom: 28, maxWidth: 500}}
						lineStyle={{
							fontFamily: fonts.body,
							fontSize: 27,
							lineHeight: 1.38,
							color: colors.inkMuted,
						}}
					/>
					<div style={{display: 'flex', flexDirection: 'column', gap: 12, maxWidth: 420}}>
						{notes.map((note, index) => {
							const rowEnter = spring({
								fps,
								frame: Math.max(0, frame - 10 - index * 5),
								config: {damping: 18, stiffness: 126},
								durationInFrames: 20,
							});

							return (
								<div
									key={note.text}
									style={{
										display: 'flex',
										alignItems: 'center',
										gap: 14,
										opacity: rowEnter,
										transform: `translateY(${interpolate(rowEnter, [0, 1], [10, 0])}px)`,
										filter: `blur(${interpolate(rowEnter, [0, 1], [6, 0])}px)`,
									}}
								>
									<div
										style={{
											width: 34,
											height: 2,
											borderRadius: 2,
											background: note.tone,
											flexShrink: 0,
										}}
									/>
									<div
										style={{
											fontFamily: fonts.body,
											fontSize: 22,
											lineHeight: 1.25,
											color: colors.ink,
											fontWeight: 600,
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
						top: 112,
						bottom: 82,
						display: 'flex',
						alignItems: 'center',
						justifyContent: 'center',
						perspective: 1800,
						opacity: enter,
						transform: `translateX(${phoneX}px) translateY(${phoneY}px) scale(${phoneScale}) rotateX(${phoneRotateX}deg) rotateY(${phoneRotateY}deg) rotateZ(${phoneRotateZ}deg)`,
					}}
				>
					<PhoneMockup
						imageSrc="clips/iphone-call-green.png"
						glowIntensity={0}
						glassOverlayOpacity={0.48}
						angledReflectionOpacity={0.22}
						topReflectionOpacity={0.28}
						shadowStrength={1.24}
						scale={1.05}
					/>
				</div>
			</AbsoluteFill>
		</SceneContainer>
	);
};
