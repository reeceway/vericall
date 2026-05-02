import React from 'react';
import {AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {PhoneMockup} from '../components/PhoneMockup';
import {SceneContainer} from '../components/SceneContainer';
import {colors, fonts} from '../theme';

const details = [
	{text: 'MSP rollout', tone: colors.accent},
	{text: 'On-device alerts', tone: colors.safe},
	{text: 'Real call flow', tone: colors.danger},
];

export const Scene4WhatIsVicall: React.FC<{durationInFrames?: number}> = ({durationInFrames}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const textProgress = spring({
		fps,
		frame,
		config: {damping: 180, stiffness: 210},
		durationInFrames: 20,
	});
	const phoneProgress = spring({
		fps,
		frame: Math.max(0, frame - 10),
		config: {damping: 16, stiffness: 122},
		durationInFrames: 26,
	});
	const phoneRotateY = interpolate(phoneProgress, [0, 1], [-18, -8]);
	const phoneRotateX = interpolate(phoneProgress, [0, 1], [8, 3]);
	const phoneRotateZ = interpolate(phoneProgress, [0, 1], [7, 1.2]);

	return (
		<SceneContainer
			durationInFrames={durationInFrames}
			background="linear-gradient(180deg, #fcfdff 0%, #f3f7fd 100%)"
		>
			<AbsoluteFill style={{overflow: 'hidden'}}>
				<div
					style={{
						position: 'absolute',
						top: 132,
						right: 128,
						width: 500,
						height: 500,
						borderRadius: '50%',
						background:
							'radial-gradient(circle, rgba(77,124,255,0.045) 0%, rgba(77,124,255,0.015) 34%, rgba(77,124,255,0) 72%)',
						filter: 'blur(18px)',
					}}
				/>
				<div
					style={{
						position: 'absolute',
						left: -120,
						bottom: -140,
						width: 620,
						height: 620,
						borderRadius: '50%',
						background:
							'radial-gradient(circle, rgba(0,230,118,0.032) 0%, rgba(0,230,118,0.012) 38%, rgba(0,230,118,0) 76%)',
						filter: 'blur(22px)',
					}}
				/>

				<div
					style={{
						flex: 1,
						display: 'grid',
						gridTemplateColumns: '0.92fr 1.08fr',
						alignItems: 'center',
						padding: '0 118px',
						gap: 42,
					}}
				>
					<div
						style={{
							opacity: textProgress,
							transform: `translateY(${interpolate(textProgress, [0, 1], [24, 0])}px)`,
						}}
					>
						<div
							style={{
								fontFamily: fonts.body,
								fontSize: 18,
								letterSpacing: 2.3,
								textTransform: 'uppercase',
								color: colors.accent,
								marginBottom: 18,
								fontWeight: 700,
							}}
						>
							Secure Calling For Teams
						</div>
						<div
							style={{
								fontFamily: fonts.headline,
								fontWeight: 800,
								fontSize: 72,
								lineHeight: 1.02,
								color: colors.text,
								maxWidth: 660,
								marginBottom: 18,
							}}
						>
							Vicall adds trust to the call, not friction to the user.
						</div>
						<div
							style={{
								fontFamily: fonts.body,
								fontSize: 26,
								lineHeight: 1.38,
								color: colors.muted,
								maxWidth: 620,
								marginBottom: 26,
							}}
						>
							Install it once. Keep the normal calling flow. Surface risk only when the call needs attention.
						</div>

						<div
							style={{
								display: 'flex',
								flexDirection: 'column',
								gap: 14,
								maxWidth: 520,
							}}
						>
							{details.map((detail) => (
								<div
									key={detail.text}
									style={{
										display: 'flex',
										alignItems: 'center',
										gap: 14,
									}}
								>
									<div
										style={{
											width: 34,
											height: 2,
											borderRadius: 2,
											background: detail.tone,
											flexShrink: 0,
										}}
									/>
									<div
										style={{
											fontFamily: fonts.body,
											fontSize: 22,
											lineHeight: 1.25,
											color: colors.text,
											fontWeight: 600,
										}}
									>
										{detail.text}
									</div>
								</div>
							))}
						</div>
					</div>

					<div
						style={{
							display: 'flex',
							justifyContent: 'center',
							alignItems: 'center',
							perspective: 2200,
							transform: `translateX(${interpolate(phoneProgress, [0, 1], [80, 0])}px) translateY(${interpolate(
								phoneProgress,
								[0, 1],
								[16, 0]
							)}px) scale(${interpolate(phoneProgress, [0, 1], [0.94, 1])}) rotateX(${phoneRotateX}deg) rotateY(${phoneRotateY}deg) rotateZ(${phoneRotateZ}deg)`,
							opacity: phoneProgress,
							position: 'relative',
						}}
					>
						<PhoneMockup
							imageSrc="clips/iphone-app-home.png"
							glowIntensity={0}
							glassOverlayOpacity={0.56}
							angledReflectionOpacity={0.28}
							topReflectionOpacity={0.4}
							shadowStrength={1.24}
							placeholderTitle="Vicall Home"
							placeholderBody="Show the actual app home screen and recent call state."
							scale={1.06}
						/>
					</div>
				</div>
			</AbsoluteFill>
		</SceneContainer>
	);
};
